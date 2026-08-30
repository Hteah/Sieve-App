import AVFoundation
import Foundation
import os

/// Target sample rate for batch conversion.
enum SampleRateOption: Int, CaseIterable, Identifiable, Sendable {
    case keep = 0
    case r44100 = 44_100
    case r48000 = 48_000
    case r88200 = 88_200
    case r96000 = 96_000
    case r176400 = 176_400
    case r192000 = 192_000

    var id: Int { rawValue }
    var label: String {
        guard self != .keep else { return "Keep original" }
        let khz = Double(rawValue) / 1000
        return khz == khz.rounded() ? "\(Int(khz)) kHz" : String(format: "%.1f kHz", khz)
    }
}

/// Target sample format for batch conversion. Output is always a WAV.
enum BitDepthOption: String, CaseIterable, Identifiable, Sendable {
    case keep
    case int16
    case int24
    case float32

    var id: String { rawValue }
    var label: String {
        switch self {
        case .keep: "Keep original"
        case .int16: "16-bit int"
        case .int24: "24-bit int"
        case .float32: "32-bit float"
        }
    }
}

struct ConvertSettings: Sendable, Equatable {
    var sampleRate: SampleRateOption = .keep
    var bitDepth: BitDepthOption = .int24

    /// True when neither dimension changes (still meaningful for a non-WAV source: it becomes WAV).
    var isNoOp: Bool { sampleRate == .keep && bitDepth == .keep }
}

struct ConvertJob: Sendable {
    var sampleId: Int64
    var source: URL
    var oldContentHash: String?
    var rootId: Int64
}

struct ConvertResult: Identifiable, Sendable {
    var id: Int64
    var filename: String
    var outcome: Outcome

    enum Outcome: Sendable, Equatable {
        case converted(finalURL: URL, newHash: String?)
        case skippedNoOp
        case failed(String)
    }

    var succeeded: Bool { if case .converted = outcome { true } else { false } }
}

/// Rewrites audio files in place: sample-rate conversion + bit-depth change, WAV output.
/// A non-WAV source is replaced by a sibling `.wav` and the original is deleted. Pure and
/// off-actor; call from a detached task. Never mutates the original until the new file is
/// written and validated.
enum AudioConverter {
    private static let log = Logger(subsystem: "com.arlo.Sieve", category: "convert")

    static func convert(job: ConvertJob, settings: ConvertSettings) -> ConvertResult {
        let source = job.source
        let filename = source.lastPathComponent
        let fm = FileManager.default
        let dir = source.deletingLastPathComponent()
        let sourceIsWav = source.pathExtension.lowercased() == "wav"
        let finalURL = sourceIsWav
            ? source
            : dir.appending(path: (filename as NSString).deletingPathExtension + ".wav")

        if settings.isNoOp && sourceIsWav {
            return ConvertResult(id: job.sampleId, filename: filename, outcome: .skippedNoOp)
        }
        if finalURL != source, fm.fileExists(atPath: finalURL.path) {
            return ConvertResult(id: job.sampleId, filename: filename,
                                 outcome: .failed("“\(finalURL.lastPathComponent)” already exists next to the original."))
        }

        let temp = dir.appending(path: ".sieve-convert-\(UUID().uuidString).wav")
        do {
            try runConversion(source: source, destination: temp, settings: settings)
            try validate(temp: temp, source: source, settings: settings)

            if finalURL == source {
                _ = try fm.replaceItemAt(source, withItemAt: temp)
            } else {
                try fm.moveItem(at: temp, to: finalURL)
                do {
                    try fm.removeItem(at: source)
                } catch {
                    log.error("converted \(filename, privacy: .public) but could not delete the original: \(error, privacy: .public)")
                }
            }
            let newHash = AudioAnalyzer.analyze(url: finalURL).audioHash
            return ConvertResult(id: job.sampleId, filename: filename,
                                 outcome: .converted(finalURL: finalURL, newHash: newHash))
        } catch {
            try? fm.removeItem(at: temp)
            log.error("convert failed for \(filename, privacy: .public): \(error, privacy: .public)")
            let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return ConvertResult(id: job.sampleId, filename: filename, outcome: .failed(msg))
        }
    }

    // MARK: Conversion

    private static func runConversion(source: URL, destination: URL, settings: ConvertSettings) throws {
        let srcFile = try AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32, interleaved: false)
        let srcFormat = srcFile.processingFormat
        guard srcFormat.channelCount > 0 else { throw ConvertError.unsupportedSource }

        let targetSR = settings.sampleRate == .keep ? srcFile.fileFormat.sampleRate : Double(settings.sampleRate.rawValue)
        let outSettings = pcmSettings(sampleRate: targetSR,
                                      channels: Int(srcFormat.channelCount),
                                      bitDepth: resolvedBitDepth(settings.bitDepth, source: srcFile.fileFormat))
        let outFile = try AVAudioFile(forWriting: destination, settings: outSettings,
                                      commonFormat: .pcmFormatFloat32, interleaved: false)
        let dstFormat = outFile.processingFormat

        guard let converter = AVAudioConverter(from: srcFormat, to: dstFormat) else {
            throw ConvertError.converterUnavailable
        }
        converter.sampleRateConverterQuality = .max
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering

        let inCapacity: AVAudioFrameCount = 1 << 16
        let ratio = max(dstFormat.sampleRate / srcFormat.sampleRate, 0.001)
        let outCapacity = AVAudioFrameCount((Double(inCapacity) * ratio).rounded(.up)) + 8192
        guard let inBuffer = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: inCapacity) else {
            throw ConvertError.allocationFailed
        }

        var reachedEnd = false
        while true {
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: dstFormat, frameCapacity: outCapacity) else {
                throw ConvertError.allocationFailed
            }
            var nsError: NSError?
            let status = converter.convert(to: outBuffer, error: &nsError) { _, inputStatus in
                if reachedEnd {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    try srcFile.read(into: inBuffer)
                } catch {
                    reachedEnd = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                if inBuffer.frameLength == 0 {
                    reachedEnd = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = .haveData
                return inBuffer
            }
            if let nsError { throw nsError }
            if outBuffer.frameLength > 0 { try outFile.write(from: outBuffer) }
            switch status {
            case .haveData:
                continue
            case .inputRanDry:
                if reachedEnd { return }
            case .endOfStream:
                return
            case .error:
                throw ConvertError.conversionFailed
            @unknown default:
                return
            }
        }
    }

    /// Re-opens the freshly written file and checks it matches what was asked for.
    private static func validate(temp: URL, source: URL, settings: ConvertSettings) throws {
        let out = try AVAudioFile(forReading: temp)
        let src = try AVAudioFile(forReading: source)
        guard out.length > 0 else { throw ConvertError.emptyOutput }
        let targetSR = settings.sampleRate == .keep ? src.fileFormat.sampleRate : Double(settings.sampleRate.rawValue)
        guard abs(out.fileFormat.sampleRate - targetSR) < 1 else { throw ConvertError.wrongSampleRate }
        guard out.fileFormat.channelCount == src.fileFormat.channelCount else { throw ConvertError.wrongChannels }
        let expected = Double(src.length) * (targetSR / src.fileFormat.sampleRate)
        guard Double(out.length) > expected * 0.9 - 64 else { throw ConvertError.truncated }
    }

    private enum ResolvedBits { case int(Int); case float }

    private static func resolvedBitDepth(_ option: BitDepthOption, source: AVAudioFormat) -> ResolvedBits {
        switch option {
        case .int16: return .int(16)
        case .int24: return .int(24)
        case .float32: return .float
        case .keep:
            let asbd = source.streamDescription.pointee
            if asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 { return .float }
            switch asbd.mBitsPerChannel {
            case 8, 16: return .int(16)
            case 24: return .int(24)
            default: return .int(24)
            }
        }
    }

    private static func pcmSettings(sampleRate: Double, channels: Int, bitDepth: ResolvedBits) -> [String: Any] {
        var s: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        switch bitDepth {
        case .int(let bits):
            s[AVLinearPCMBitDepthKey] = bits
            s[AVLinearPCMIsFloatKey] = false
        case .float:
            s[AVLinearPCMBitDepthKey] = 32
            s[AVLinearPCMIsFloatKey] = true
        }
        return s
    }

    enum ConvertError: Error, LocalizedError {
        case unsupportedSource
        case converterUnavailable
        case allocationFailed
        case conversionFailed
        case emptyOutput
        case wrongSampleRate
        case wrongChannels
        case truncated

        var errorDescription: String? {
            switch self {
            case .unsupportedSource: "The file could not be decoded."
            case .converterUnavailable: "No converter is available for this format."
            case .allocationFailed: "Ran out of memory during conversion."
            case .conversionFailed: "The audio conversion failed."
            case .emptyOutput: "The converted file came out empty."
            case .wrongSampleRate: "The converted file has the wrong sample rate."
            case .wrongChannels: "The converted file has the wrong channel count."
            case .truncated: "The converted file is shorter than expected."
            }
        }
    }
}
