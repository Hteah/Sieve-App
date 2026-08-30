import AVFoundation
import Foundation
import os

/// Shared audio file I/O: decode to an in-memory `AudioClip`, write a clip back out as WAV,
/// and the temp-file → validate → atomic-replace discipline used by both the batch converter
/// and the inspector editor. Pure and off-actor; call from a detached task.
enum AudioFileIO {
    private static let log = Logger(subsystem: "com.arlo.Sieve", category: "audioio")

    enum ResolvedBits: Sendable { case int(Int); case float }

    enum IOError: Error, LocalizedError {
        case undecodable
        case tooLong
        case emptyOutput
        case wrongSampleRate
        case wrongChannels
        case truncated
        case siblingExists(String)

        var errorDescription: String? {
            switch self {
            case .undecodable: "The file could not be decoded."
            case .tooLong: "The file is longer than the editor's limit."
            case .emptyOutput: "The written file came out empty."
            case .wrongSampleRate: "The written file has the wrong sample rate."
            case .wrongChannels: "The written file has the wrong channel count."
            case .truncated: "The written file is shorter than expected."
            case .siblingExists(let name): "“\(name)” already exists next to the original."
            }
        }
    }

    // MARK: Bit-depth resolution + PCM settings

    static func resolvedBits(_ option: BitDepthOption, sourceFormat: AVAudioFormat) -> ResolvedBits {
        switch option {
        case .int16: return .int(16)
        case .int24: return .int(24)
        case .float32: return .float
        case .keep:
            let asbd = sourceFormat.streamDescription.pointee
            if asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 { return .float }
            switch asbd.mBitsPerChannel {
            case 8, 16: return .int(16)
            case 24: return .int(24)
            default: return .int(24)
            }
        }
    }

    static func pcmSettings(sampleRate: Double, channels: Int, bits: ResolvedBits) -> [String: Any] {
        var s: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        switch bits {
        case .int(let n):
            s[AVLinearPCMBitDepthKey] = n
            s[AVLinearPCMIsFloatKey] = false
        case .float:
            s[AVLinearPCMBitDepthKey] = 32
            s[AVLinearPCMIsFloatKey] = true
        }
        return s
    }

    // MARK: Load / write

    /// Decodes the whole file to de-interleaved Float32. Throws `.tooLong` past `maxFrames`.
    static func load(url: URL, maxFrames: Int) throws -> AudioClip {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            throw IOError.undecodable
        }
        let format = file.processingFormat
        let channels = Int(format.channelCount)
        let total = Int(file.length)
        guard channels > 0, total > 0 else { throw IOError.undecodable }
        guard total <= maxFrames else { throw IOError.tooLong }

        var out = Array(repeating: [Float](), count: channels)
        for c in 0..<channels { out[c].reserveCapacity(total) }
        let chunk: AVAudioFrameCount = 1 << 16
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else {
            throw IOError.undecodable
        }
        while file.framePosition < file.length {
            try file.read(into: buffer)
            let n = Int(buffer.frameLength)
            if n == 0 { break }
            guard let chans = buffer.floatChannelData else { break }
            for c in 0..<channels {
                out[c].append(contentsOf: UnsafeBufferPointer(start: chans[c], count: n))
            }
        }
        return AudioClip(channels: out, sampleRate: format.sampleRate)
    }

    static func writeWAV(_ clip: AudioClip, to url: URL, bits: ResolvedBits) throws {
        let channels = max(1, clip.channelCount)
        let settings = pcmSettings(sampleRate: clip.sampleRate, channels: channels, bits: bits)
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: clip.sampleRate,
                                         channels: AVAudioChannelCount(channels), interleaved: false) else {
            throw IOError.undecodable
        }
        let total = clip.frameCount
        var offset = 0
        let chunk = 1 << 16
        while offset < total {
            let n = min(chunk, total - offset)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)) else {
                throw IOError.emptyOutput
            }
            buffer.frameLength = AVAudioFrameCount(n)
            let dst = buffer.floatChannelData!
            for c in 0..<channels {
                clip.channels[c].withUnsafeBufferPointer { src in
                    dst[c].update(from: src.baseAddress! + offset, count: n)
                }
            }
            try file.write(from: buffer)
            offset += n
        }
    }

    // MARK: Replace / validate

    static func wavSiblingURL(for url: URL) -> URL {
        url.deletingLastPathComponent()
            .appending(path: (url.lastPathComponent as NSString).deletingPathExtension + ".wav")
    }

    /// Puts `tempURL` in `originalURL`'s place: a `.wav` original is replaced atomically; any other
    /// container is superseded by a sibling `.wav` and the original deleted. Returns the final URL.
    @discardableResult
    static func replaceInPlace(originalURL: URL, tempURL: URL) throws -> URL {
        let fm = FileManager.default
        if originalURL.pathExtension.lowercased() == "wav" {
            _ = try fm.replaceItemAt(originalURL, withItemAt: tempURL)
            return originalURL
        }
        let finalURL = wavSiblingURL(for: originalURL)
        if fm.fileExists(atPath: finalURL.path) { throw IOError.siblingExists(finalURL.lastPathComponent) }
        try fm.moveItem(at: tempURL, to: finalURL)
        do {
            try fm.removeItem(at: originalURL)
        } catch {
            log.error("wrote \(finalURL.lastPathComponent, privacy: .public) but could not delete the original: \(error, privacy: .public)")
        }
        return finalURL
    }

    static func validateFile(at url: URL, expectedRate: Double, expectedChannels: Int, minFrames: Int) throws {
        let f = try AVAudioFile(forReading: url)
        guard f.length > 0 else { throw IOError.emptyOutput }
        guard abs(f.fileFormat.sampleRate - expectedRate) < 1 else { throw IOError.wrongSampleRate }
        guard Int(f.fileFormat.channelCount) == expectedChannels else { throw IOError.wrongChannels }
        guard Int(f.length) >= minFrames else { throw IOError.truncated }
    }
}
