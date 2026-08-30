import Foundation
import Testing
@testable import Sieve

struct IncrementalScannerTests {
    let d0 = Date(timeIntervalSinceReferenceDate: 1_000_000)

    @Test func classifiesAddedModifiedUnchangedRemoved() {
        let existing: [String: IndexedEntry] = [
            "a.wav": IndexedEntry(id: 1, fileSize: 10, modifiedAt: d0, status: .present),
            "b.wav": IndexedEntry(id: 2, fileSize: 20, modifiedAt: d0, status: .present),
            "gone.wav": IndexedEntry(id: 3, fileSize: 30, modifiedAt: d0, status: .present),
        ]
        let found = [
            FileEntry(relativePath: "a.wav", fileSize: 10, modifiedAt: d0),
            FileEntry(relativePath: "b.wav", fileSize: 21, modifiedAt: d0),
            FileEntry(relativePath: "new/c.wav", fileSize: 5, modifiedAt: d0),
        ]
        let diff = IncrementalScanner.diff(existing: existing, found: found)
        #expect(diff.unchanged == [1])
        #expect(diff.modified.map(\.id) == [2])
        #expect(diff.added.map(\.relativePath) == ["new/c.wav"])
        #expect(diff.removed == [3])
    }

    @Test func subSecondTimestampDriftIsUnchanged() {
        let existing = ["a.wav": IndexedEntry(id: 1, fileSize: 10, modifiedAt: d0, status: .present)]
        let found = [FileEntry(relativePath: "a.wav", fileSize: 10, modifiedAt: d0.addingTimeInterval(0.4))]
        #expect(IncrementalScanner.diff(existing: existing, found: found).unchanged == [1])
    }

    @Test func missingFileThatReappearsIsUnchanged() {
        let existing = ["a.wav": IndexedEntry(id: 1, fileSize: 10, modifiedAt: d0, status: .missing)]
        let found = [FileEntry(relativePath: "a.wav", fileSize: 10, modifiedAt: d0)]
        let diff = IncrementalScanner.diff(existing: existing, found: found)
        #expect(diff.unchanged == [1] && diff.removed.isEmpty)
    }

    @Test func enumeratesOnlyAudioFilesWithRelativePaths() throws {
        let dir = try Fixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appending(path: "Kicks"), withIntermediateDirectories: true)
        try Fixtures.writeTone(to: dir.appending(path: "Kicks/k1.wav"))
        try Fixtures.writeTone(to: dir.appending(path: "top.aif"))
        try Data("x".utf8).write(to: dir.appending(path: "readme.txt"))
        let entries = try FileEnumerator.audioFiles(under: dir, extensions: Set(Queries.audioExtensions))
        #expect(Set(entries.map(\.relativePath)) == ["Kicks/k1.wav", "top.aif"])
        #expect(entries.allSatisfy { $0.fileSize > 0 })
    }
}
