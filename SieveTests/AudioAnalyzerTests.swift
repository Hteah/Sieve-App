import Foundation
import Testing
@testable import Sieve

struct AudioAnalyzerTests {
    @Test func wavAndAiffWithSameAudioShareAudioHash() throws {
        let dir = try Fixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = try Fixtures.writeTone(to: dir.appending(path: "a.wav"))
        let aif = try Fixtures.writeTone(to: dir.appending(path: "a.aif"))
        let other = try Fixtures.writeTone(to: dir.appending(path: "b.wav"), frequency: 880)
        let ha = AudioAnalyzer.analyze(url: wav)
        let hb = AudioAnalyzer.analyze(url: aif)
        let hc = AudioAnalyzer.analyze(url: other)
        #expect(ha.audioHash != nil)
        #expect(ha.audioHash == hb.audioHash)
        #expect(ha.audioHash != hc.audioHash)
        #expect(ha.fileHash == nil)
    }

    @Test func extraMetadataChunkDoesNotChangeAudioHash() throws {
        let dir = try Fixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try Fixtures.writeTone(to: dir.appending(path: "a.wav"))
        let b = try Fixtures.writeTone(to: dir.appending(path: "b.wav"))
        try Fixtures.appendMetadataChunk(toWav: b)
        #expect(try AudioAnalyzer.fileHash(url: a) != AudioAnalyzer.fileHash(url: b))
        #expect(AudioAnalyzer.analyze(url: a).audioHash == AudioAnalyzer.analyze(url: b).audioHash)
    }

    @Test func metadataAndLevels() throws {
        let dir = try Fixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // 0.5 gain sine → peak -6.02 dBFS, RMS -9.03 dBFS
        let url = try Fixtures.writeTone(to: dir.appending(path: "s.wav"), seconds: 1, sampleRate: 48_000, channels: 2, gain: 0.5, bitDepth: 24)
        let a = AudioAnalyzer.analyze(url: url)
        let m = try #require(a.metadata)
        #expect(m.sampleRate == 48_000)
        #expect(m.channels == 2)
        #expect(m.bitDepth == 24)
        #expect(abs(m.durationSec - 1) < 0.001)
        #expect(m.formatName == "WAV PCM")
        #expect(abs((a.peakDb ?? 0) - (-6.02)) < 0.05)
        #expect(abs((a.rmsDb ?? 0) - (-9.03)) < 0.05)
        #expect(a.clippedSamples == 0)
    }

    @Test func clippingIsCounted() throws {
        let dir = try Fixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try Fixtures.writeTone(to: dir.appending(path: "c.wav"), gain: 0.3, clipFrames: 100)
        let a = AudioAnalyzer.analyze(url: url)
        #expect(a.clippedSamples == 100)
        #expect((a.peakDb ?? -100) > -0.1)
    }

    @Test func waveformSummaryRoundTripsAndTracksAmplitude() throws {
        let dir = try Fixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try Fixtures.writeTone(to: dir.appending(path: "w.wav"), seconds: 1, channels: 2, gain: 0.8, square: true)
        let a = AudioAnalyzer.analyze(url: url)
        let wf = try #require(a.waveform)
        #expect(wf.channels == 2)
        #expect(wf.bucketCount == WaveformSummary.thumbnailBuckets)
        // Square wave: peak ≈ rms ≈ 0.8 in every bucket.
        #expect(wf.peaks[0].allSatisfy { abs($0 - 0.8) < 0.01 })
        #expect(wf.rms[1].allSatisfy { abs($0 - 0.8) < 0.01 })
        let decoded = try #require(WaveformSummary(encoded: wf.encoded()))
        #expect(decoded.bucketCount == wf.bucketCount && decoded.channels == 2)
        #expect(abs(decoded.peaks[1][10] - wf.peaks[1][10]) < 0.001)
        // Full-res generator over a sub-range still works.
        let zoomed = try WaveformGenerator.summary(url: url, buckets: 64, range: 0..<4410)
        #expect(zoomed.bucketCount == 64)
        #expect(zoomed.peaks[0].allSatisfy { abs($0 - 0.8) < 0.01 })
    }

    @Test func undecodableFileFallsBackToFileHash() throws {
        let dir = try Fixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "junk.wav")
        try Data(repeating: 7, count: 2048).write(to: url)
        let a = AudioAnalyzer.analyze(url: url)
        #expect(a.audioHash == nil)
        #expect(a.fileHash?.count == 64)
        #expect(a.metadata == nil)
    }
}
