import AVFoundation
import CryptoKit
import Foundation
import os

struct AudioMetadata: Hashable, Sendable {
    var durationSec: Double
    var sampleRate: Double
    var channels: Int
    var bitDepth: Int?
    var formatName: String
    var frameCount: Int64
}

/// Everything the enrichment pass learns about one file. All value types → Sendable.
struct AudioAnalysis: Sendable {
    var metadata: AudioMetadata?
    var audioHash: String?
    var fileHash: String?
    var waveform: WaveformSummary?
    var peakDb: Double?
    var rmsDb: Double?
    var clippedSamples: Int?
    var hints: FilenameHints.Result
}

enum AudioAnalyzer {
    private static let log = Logger(subsystem: "com.arlo.Sieve", category: "analyze")
    static let chunkFrames: AVAudioFrameCount = 65_536
    static let clipThreshold: Float = 0.999

    /// One pass over the file: metadata, PCM hash, waveform summary, level stats.
    /// Falls back to a whole-file hash when AVFoundation can't decode it.
    static func analyze(url: URL, buckets: Int = WaveformSummary.thumbnailBuckets) -> AudioAnalysis {
        let hints = FilenameHints.parse(url.lastPathComponent)
        do {
            let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
            let meta = metadata(of: file, ext: url.pathExtension)
            let format = file.processingFormat
            let channels = Int(format.channelCount)
            let total = file.length
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
                throw CocoaError(.fileReadCorruptFile)
            }

            var hasher = SHA256()
            hasher.update(data: Data("sieve-pcm-v1|\(Int(format.sampleRate))|\(channels)|".utf8))
            var acc = WaveformAccumulator(bucketCount: buckets, channels: channels, totalFrames: total)
            var peak: Float = 0
            var sumSq: Double = 0
            var frames: Int64 = 0
            var clipped = 0

            while file.framePosition < total {
                try file.read(into: buffer, frameCount: chunkFrames)
                let n = Int(buffer.frameLength)
                if n == 0 { break }
                guard let chans = buffer.floatChannelData else { break }
                var ptrs: [UnsafePointer<Float>] = []
                for c in 0..<channels {
                    let p = UnsafePointer(chans[c])
                    ptrs.append(p)
                    hasher.update(bufferPointer: UnsafeRawBufferPointer(start: p, count: n * MemoryLayout<Float>.size))
                    var localPeak: Float = 0
                    var localSum: Double = 0
                    var localClip = 0
                    for i in 0..<n {
                        let v = p[i]
                        let a = abs(v)
                        if a > localPeak { localPeak = a }
                        if a >= clipThreshold { localClip += 1 }
                        localSum += Double(v * v)
                    }
                    peak = max(peak, localPeak)
                    sumSq += localSum
                    clipped += localClip
                }
                acc.consume(channelData: ptrs, frameCount: n)
                frames += Int64(n)
            }

            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            let samples = Double(frames) * Double(channels)
            let rms = samples > 0 ? (sumSq / samples).squareRoot() : 0
            return AudioAnalysis(
                metadata: meta,
                audioHash: digest,
                fileHash: nil,
                waveform: acc.summary(),
                peakDb: dbfs(Double(peak)),
                rmsDb: dbfs(rms),
                clippedSamples: clipped,
                hints: hints
            )
        } catch {
            log.notice("AVAudioFile failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return AudioAnalysis(metadata: nil, audioHash: nil, fileHash: try? fileHash(url: url),
                                 waveform: nil, peakDb: nil, rmsDb: nil, clippedSamples: nil, hints: hints)
        }
    }

    static func dbfs(_ linear: Double) -> Double {
        linear > 0 ? 20 * log10(linear) : -120
    }

    static func metadata(of file: AVAudioFile, ext: String) -> AudioMetadata {
        let ff = file.fileFormat
        let asbd = ff.streamDescription.pointee
        let sr = ff.sampleRate
        let bits = asbd.mBitsPerChannel > 0 ? Int(asbd.mBitsPerChannel) : nil
        let name: String
        switch asbd.mFormatID {
        case kAudioFormatLinearPCM:
            let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
            name = "\(ext.uppercased()) \(isFloat ? "Float" : "PCM")"
        case kAudioFormatMPEGLayer3: name = "MP3"
        case kAudioFormatMPEG4AAC: name = "AAC"
        case kAudioFormatAppleLossless: name = "ALAC"
        case kAudioFormatFLAC: name = "FLAC"
        default: name = fourCC(asbd.mFormatID)
        }
        return AudioMetadata(
            durationSec: sr > 0 ? Double(file.length) / sr : 0,
            sampleRate: sr,
            channels: Int(ff.channelCount),
            bitDepth: bits,
            formatName: name,
            frameCount: file.length
        )
    }

    private static func fourCC(_ code: UInt32) -> String {
        let bytes = [UInt8(code >> 24 & 0xff), UInt8(code >> 16 & 0xff), UInt8(code >> 8 & 0xff), UInt8(code & 0xff)]
        return String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? "?"
    }

    static func fileHash(url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// On-demand, higher-resolution waveform for the inspector (re-reads the file).
enum WaveformGenerator {
    /// `range` in frames; nil = whole file.
    static func summary(url: URL, buckets: Int, range: Range<Int64>? = nil) throws -> WaveformSummary {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        let channels = Int(format.channelCount)
        let r = range ?? 0..<file.length
        let start = max(0, r.lowerBound)
        let end = min(file.length, r.upperBound)
        let count = max(0, end - start)
        var acc = WaveformAccumulator(bucketCount: buckets, channels: channels, totalFrames: count)
        guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AudioAnalyzer.chunkFrames) else {
            return acc.summary()
        }
        file.framePosition = start
        var remaining = count
        while remaining > 0 {
            let want = AVAudioFrameCount(min(Int64(AudioAnalyzer.chunkFrames), remaining))
            try file.read(into: buffer, frameCount: want)
            let n = Int(buffer.frameLength)
            if n == 0 { break }
            guard let chans = buffer.floatChannelData else { break }
            let ptrs = (0..<channels).map { UnsafePointer(chans[$0]) }
            acc.consume(channelData: ptrs, frameCount: n)
            remaining -= Int64(n)
        }
        return acc.summary()
    }
}
