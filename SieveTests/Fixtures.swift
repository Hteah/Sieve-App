import AVFoundation
import Foundation

/// Generates small audio files for tests.
enum Fixtures {
    static func tempDir(_ name: String = UUID().uuidString) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "SieveTests-\(name)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Writes a PCM file. `gain` scales the sine; frames at `clipFrames` are forced to full scale.
    @discardableResult
    static func writeTone(to url: URL, seconds: Double = 0.5, sampleRate: Double = 44_100, channels: Int = 1,
                          frequency: Double = 440, gain: Float = 0.5, bitDepth: Int = 16, clipFrames: Int = 0,
                          square: Bool = false) throws -> URL {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: AVAudioChannelCount(channels), interleaved: false)!
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for c in 0..<channels {
            let p = buffer.floatChannelData![c]
            for i in 0..<Int(frames) {
                let t = Double(i) / sampleRate
                var v = Float(sin(2 * .pi * frequency * t))
                if square { v = v >= 0 ? 1 : -1 }
                v *= gain
                if i < clipFrames { v = 1.0 }
                p[i] = v
            }
        }
        let ext = url.pathExtension.lowercased()
        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: bitDepth,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        settings[AVLinearPCMIsBigEndianKey] = (ext == "aif" || ext == "aiff")
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
        return url
    }

    /// Appends a LIST/INFO chunk to a WAV so its bytes differ while audio stays identical.
    static func appendMetadataChunk(toWav url: URL) throws {
        var data = try Data(contentsOf: url)
        var chunk = Data("LIST".utf8)
        let body = Data("INFOISFT\u{08}\u{00}\u{00}\u{00}SieveTst".utf8)
        var size = UInt32(body.count).littleEndian
        withUnsafeBytes(of: &size) { chunk.append(contentsOf: $0) }
        chunk.append(body)
        data.append(chunk)
        // Patch RIFF size (bytes 4..<8).
        var riff = UInt32(data.count - 8).littleEndian
        withUnsafeBytes(of: &riff) { data.replaceSubrange(4..<8, with: $0) }
        try data.write(to: url)
    }
}
