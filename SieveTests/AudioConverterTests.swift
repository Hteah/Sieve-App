import AVFoundation
import Foundation
import Testing
@testable import Sieve

struct AudioConverterTests {
    @Test func downsamplesAndReducesBitDepthInPlace() throws {
        let dir = try Fixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try Fixtures.writeTone(to: dir.appending(path: "tone.wav"),
                                        seconds: 1, sampleRate: 96_000, channels: 2, bitDepth: 24)
        let before = AudioAnalyzer.analyze(url: url).audioHash

        let job = ConvertJob(sampleId: 1, source: url, oldContentHash: before, rootId: 1)
        let result = AudioConverter.convert(job: job, settings: ConvertSettings(sampleRate: .r48000, bitDepth: .int16))

        guard case let .converted(finalURL, newHash) = result.outcome else {
            Issue.record("expected a conversion, got \(result.outcome)")
            return
        }
        #expect(finalURL == url)
        #expect(FileManager.default.fileExists(atPath: url.path))
        let meta = try #require(AudioAnalyzer.analyze(url: url).metadata)
        #expect(meta.sampleRate == 48_000)
        #expect(meta.bitDepth == 16)
        #expect(meta.channels == 2)
        #expect(abs(meta.durationSec - 1) < 0.05)
        #expect(newHash != nil)
        #expect(newHash != before)
    }

    @Test func convertsAiffToWavAndDeletesOriginal() throws {
        let dir = try Fixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let aiff = try Fixtures.writeTone(to: dir.appending(path: "kick.aiff"),
                                          seconds: 0.5, sampleRate: 44_100, channels: 1, bitDepth: 16)

        let job = ConvertJob(sampleId: 2, source: aiff, oldContentHash: nil, rootId: 1)
        let result = AudioConverter.convert(job: job, settings: ConvertSettings(sampleRate: .r48000, bitDepth: .int24))

        guard case let .converted(finalURL, _) = result.outcome else {
            Issue.record("expected a conversion, got \(result.outcome)")
            return
        }
        #expect(finalURL.pathExtension == "wav")
        #expect(finalURL.deletingPathExtension().lastPathComponent == "kick")
        #expect(!FileManager.default.fileExists(atPath: aiff.path))
        #expect(FileManager.default.fileExists(atPath: finalURL.path))
        let meta = try #require(AudioAnalyzer.analyze(url: finalURL).metadata)
        #expect(meta.sampleRate == 48_000)
        #expect(meta.bitDepth == 24)
    }

    @Test func noOpOnWavIsSkipped() throws {
        let dir = try Fixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try Fixtures.writeTone(to: dir.appending(path: "a.wav"))
        let result = AudioConverter.convert(job: ConvertJob(sampleId: 3, source: url, oldContentHash: nil, rootId: 1),
                                            settings: ConvertSettings(sampleRate: .keep, bitDepth: .keep))
        #expect(result.outcome == .skippedNoOp)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func refusesWhenWavSiblingWouldCollide() throws {
        let dir = try Fixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let aiff = try Fixtures.writeTone(to: dir.appending(path: "clash.aiff"), seconds: 0.2)
        _ = try Fixtures.writeTone(to: dir.appending(path: "clash.wav"), seconds: 0.2)

        let result = AudioConverter.convert(job: ConvertJob(sampleId: 4, source: aiff, oldContentHash: nil, rootId: 1),
                                            settings: ConvertSettings(sampleRate: .r48000, bitDepth: .int24))
        guard case .failed = result.outcome else {
            Issue.record("expected failure on collision, got \(result.outcome)")
            return
        }
        #expect(FileManager.default.fileExists(atPath: aiff.path))
    }

    @Test func carryOverCopiesRatingAndTagsToNewHash() async throws {
        let db = try AppDatabase.inMemory()
        let store = AnnotationStore(database: db)
        let old = SampleRow(id: 1, rootId: 1, relativePath: "a.wav", filename: "a.wav", parentDir: "",
                            ext: "wav", fileSize: 1, modifiedAt: .init(), audioHash: "OLD", fileHash: nil,
                            durationSec: 1, sampleRate: 96_000, channels: 2, bitDepth: 24, formatName: "WAV PCM",
                            bpm: nil, musicalKey: nil, waveform: nil, peakDb: nil, rmsDb: nil, clippedSamples: nil,
                            status: .present, rating: nil, isFavorite: nil, quickTags: nil, tagNames: nil)
        try await store.setRating(4, for: old)
        try await store.addTag(named: "kick", to: [old])

        try await store.carryOverAnnotation(from: "OLD", to: "NEW", rootId: 1, relativePath: "a.wav")

        let moved = SampleRow(id: 1, rootId: 1, relativePath: "a.wav", filename: "a.wav", parentDir: "",
                              ext: "wav", fileSize: 1, modifiedAt: .init(), audioHash: "NEW", fileHash: nil,
                              durationSec: 1, sampleRate: 48_000, channels: 2, bitDepth: 16, formatName: "WAV PCM",
                              bpm: nil, musicalKey: nil, waveform: nil, peakDb: nil, rmsDb: nil, clippedSamples: nil,
                              status: .present, rating: nil, isFavorite: nil, quickTags: nil, tagNames: nil)
        let annotation = try await db.reader.read { try Queries.annotation(db: $0, for: moved, create: false) }
        #expect(annotation?.rating == 4)
        let tagCount = try await db.reader.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM annotation_tag WHERE annotationId = ?",
                             arguments: [annotation?.id ?? -1])
        }
        #expect(tagCount == 1)
    }
}
