import AVFoundation
import Foundation
import Testing
@testable import Sieve

struct AudioFileIOTests {
    @Test func loadRoundTripsRateChannelsAndFrames() throws {
        let dir = try Fixtures.tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = try Fixtures.writeTone(to: dir.appending(path: "t.wav"),
                                        seconds: 0.5, sampleRate: 48_000, channels: 2, bitDepth: 24)
        let clip = try AudioFileIO.load(url: url, maxFrames: 10_000_000)
        #expect(clip.sampleRate == 48_000)
        #expect(clip.channelCount == 2)
        #expect(abs(clip.frameCount - 24_000) <= 1)
    }

    @Test func loadThrowsWhenTooLong() throws {
        let dir = try Fixtures.tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = try Fixtures.writeTone(to: dir.appending(path: "t.wav"), seconds: 0.5, sampleRate: 48_000)
        #expect(throws: AudioFileIO.IOError.self) {
            _ = try AudioFileIO.load(url: url, maxFrames: 100)
        }
    }

    @Test func writeThenReloadPreservesAudioForEachDepth() throws {
        let dir = try Fixtures.tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = try Fixtures.writeTone(to: dir.appending(path: "s.wav"),
                                        seconds: 0.3, sampleRate: 44_100, channels: 1, bitDepth: 24)
        let clip = try AudioFileIO.load(url: src, maxFrames: 10_000_000)
        let cases: [(String, AudioFileIO.ResolvedBits)] = [("i16", .int(16)), ("i24", .int(24)), ("f32", .float)]
        for (name, bits) in cases {
            let out = dir.appending(path: "\(name).wav")
            try AudioFileIO.writeWAV(clip, to: out, bits: bits)
            let back = try AudioFileIO.load(url: out, maxFrames: 10_000_000)
            #expect(back.sampleRate == 44_100)
            #expect(back.channelCount == 1)
            #expect(abs(back.frameCount - clip.frameCount) <= 1)
            #expect(abs(back.peakLinear(in: 0..<back.frameCount) - clip.peakLinear(in: 0..<clip.frameCount)) < 0.01)
        }
    }

    @Test func replaceInPlaceSwapsWavContentsAndKeepsPath() throws {
        let dir = try Fixtures.tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let original = try Fixtures.writeTone(to: dir.appending(path: "loop.wav"),
                                              seconds: 0.4, sampleRate: 48_000, gain: 0.2)
        let temp = dir.appending(path: ".tmp.wav")
        var clip = try AudioFileIO.load(url: original, maxFrames: 10_000_000)
        clip = clip.amplified(db: 12, in: 0..<clip.frameCount)
        try AudioFileIO.writeWAV(clip, to: temp, bits: .int(24))

        let final = try AudioFileIO.replaceInPlace(originalURL: original, tempURL: temp)
        #expect(final == original)
        #expect(!FileManager.default.fileExists(atPath: temp.path))
        let after = try AudioFileIO.load(url: original, maxFrames: 10_000_000)
        #expect(after.peakLinear(in: 0..<after.frameCount) > 0.5)   // ~0.2 * 10^(12/20) ≈ 0.8
    }

    @Test func replaceInPlaceConvertsAiffToSiblingWavAndDeletesOriginal() throws {
        let dir = try Fixtures.tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let aiff = try Fixtures.writeTone(to: dir.appending(path: "hit.aiff"),
                                          seconds: 0.2, sampleRate: 44_100, channels: 1, bitDepth: 16)
        let temp = dir.appending(path: ".tmp.wav")
        let clip = try AudioFileIO.load(url: aiff, maxFrames: 10_000_000)
        try AudioFileIO.writeWAV(clip, to: temp, bits: .int(16))

        let final = try AudioFileIO.replaceInPlace(originalURL: aiff, tempURL: temp)
        #expect(final.pathExtension == "wav")
        #expect(final.deletingPathExtension().lastPathComponent == "hit")
        #expect(!FileManager.default.fileExists(atPath: aiff.path))
        #expect(FileManager.default.fileExists(atPath: final.path))
    }
}
