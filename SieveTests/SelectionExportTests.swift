import Foundation
import Testing
@testable import Sieve

struct SelectionExportTests {
    @Test func exportNameEmbedsSelectionSeconds() {
        // 48000 frames at 48 kHz = 1.00s; 24000..<72000 -> 0.50-1.50
        let name = EditorSession.exportName(stem: "kick", range: 24_000..<72_000, sampleRate: 48_000)
        #expect(name == "kick [0.50-1.50].wav")
    }

    @Test func exportNameHandlesZeroSampleRate() {
        let name = EditorSession.exportName(stem: "x", range: 0..<10, sampleRate: 0)
        #expect(name.hasPrefix("x [") && name.hasSuffix("].wav"))
    }

    @Test func cropThenWriteThenReloadKeepsTheSelectedAudio() throws {
        let dir = try Fixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = try Fixtures.writeTone(to: dir.appending(path: "tone.wav"),
                                        seconds: 1, sampleRate: 48_000, channels: 2, bitDepth: 24)
        let clip = try AudioFileIO.load(url: src, maxFrames: 10_000_000)

        let range = 12_000..<36_000                 // 0.25s .. 0.75s
        let out = dir.appending(path: "piece.wav")
        try AudioFileIO.writeWAV(clip.cropped(to: range), to: out, bits: .int(24))

        let back = try AudioFileIO.load(url: out, maxFrames: 10_000_000)
        #expect(back.sampleRate == 48_000)
        #expect(back.channelCount == 2)
        #expect(abs(back.frameCount - range.count) <= 1)
    }
}
