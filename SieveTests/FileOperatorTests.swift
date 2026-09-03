import Foundation
import GRDB
import Testing
@testable import Sieve

/// Fake FS: "trash" moves into a fake trash dir; everything else is real file ops in temp dirs.
final class FakeFS: FileSystemOps, @unchecked Sendable {
    let trashDir: URL
    var trashed: [URL] = []
    var failTrash = false
    init(trashDir: URL) { self.trashDir = trashDir }
    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    func attributes(_ url: URL) throws -> (size: Int64, modified: Date) {
        let v = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return (Int64(v.fileSize ?? 0), v.contentModificationDate ?? .distantPast)
    }
    func trash(_ url: URL) throws {
        if failTrash { throw CocoaError(.fileWriteNoPermission) }
        let dest = trashDir.appending(path: url.lastPathComponent)
        try FileManager.default.moveItem(at: url, to: dest)
        trashed.append(dest)
    }
    func remove(_ url: URL) throws { try FileManager.default.removeItem(at: url) }
    func move(_ from: URL, to: URL) throws { try FileManager.default.moveItem(at: from, to: to) }
}

struct FileOperatorTests {
    struct World {
        let db: AppDatabase
        let root: URL
        let trash: URL
        let fs: FakeFS
        let op: FileOperator
        let rootId: Int64
    }

    func makeWorld() async throws -> World {
        let base = try Fixtures.tempDir()
        let root = base.appending(path: "Root"); let trash = base.appending(path: "Trash"); let elsewhere = base.appending(path: "Elsewhere")
        for d in [root.appending(path: "A"), root.appending(path: "B"), trash, elsewhere] {
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
        try Fixtures.writeTone(to: root.appending(path: "A/kick.wav"))
        try Fixtures.writeTone(to: root.appending(path: "B/kick.wav"))
        try Fixtures.writeTone(to: root.appending(path: "B/other.wav"), frequency: 880)
        let db = try AppDatabase.inMemory()
        let rootId: Int64 = try await db.writer.write { d in
            var r = Root(name: "Root", bookmarkData: Data(), lastResolvedPath: root.path, volumeUUID: nil)
            try r.insert(d)
            for rel in ["A/kick.wav", "B/kick.wav", "B/other.wav"] {
                let url = root.appending(path: rel)
                let v = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                var s = Sample(rootId: r.id!, relativePath: rel, fileSize: Int64(v.fileSize!), modifiedAt: v.contentModificationDate!)
                let a = AudioAnalyzer.analyze(url: url)
                s.audioHash = a.audioHash; s.indexedAt = Date()
                try s.insert(d)
            }
            return r.id!
        }
        let fs = FakeFS(trashDir: trash)
        let op = FileOperator(database: db, fs: fs, resolveRoot: { _ in root })
        return World(db: db, root: root, trash: trash, fs: fs, op: op, rootId: rootId)
    }

    func groups(_ db: AppDatabase) async throws -> [DuplicateGroup] {
        try await db.reader.read { try DuplicateFinder.groups(db: $0) }
    }

    @Test func findsGroupsOfIdenticalAudio() async throws {
        let w = try await makeWorld()
        let g = try await groups(w.db)
        #expect(g.count == 1)
        #expect(g[0].members.count == 2)
        #expect(Set(g[0].members.map(\.relativePath)) == ["A/kick.wav", "B/kick.wav"])
        #expect(g[0].wastedBytes == g[0].members[1].fileSize)
    }

    @Test func trashMarksMissingAndLogs() async throws {
        let w = try await makeWorld()
        let redundant = try await groups(w.db)[0].members.first { $0.relativePath == "B/kick.wav" }!
        let results = await w.op.perform(.trash, on: [redundant])
        #expect(results.count == 1 && results[0].succeeded)
        #expect(w.fs.trashed.count == 1)
        #expect(!FileManager.default.fileExists(atPath: w.root.appending(path: "B/kick.wav").path))
        let status = try await w.db.reader.read { try String.fetchOne($0, sql: "SELECT status FROM sample WHERE id = ?", arguments: [redundant.id]) }
        #expect(status == "missing")
        let logs = try await w.db.reader.read { try FileOpLog.fetchAll($0) }
        #expect(logs.count == 1 && logs[0].op == "trash" && logs[0].succeeded)
        #expect(try await groups(w.db).isEmpty)
    }

    @Test func trashFailureIsReportedNotHidden() async throws {
        let w = try await makeWorld()
        w.fs.failTrash = true
        let redundant = try await groups(w.db)[0].members[1]
        let results = await w.op.perform(.trash, on: [redundant])
        #expect(results[0].succeeded == false)
        #expect(results[0].error != nil)
        let status = try await w.db.reader.read { try String.fetchOne($0, sql: "SELECT status FROM sample WHERE id = ?", arguments: [redundant.id]) }
        #expect(status == "present")
    }

    @Test func refusesFilesChangedSinceIndexing() async throws {
        let w = try await makeWorld()
        let redundant = try await groups(w.db)[0].members[1]
        try Fixtures.writeTone(to: w.root.appending(path: redundant.relativePath), seconds: 0.9)  // different size
        let results = await w.op.perform(.trash, on: [redundant])
        #expect(results[0].succeeded == false)
        #expect(w.fs.trashed.isEmpty)
    }

    @Test func moveInsideRootRepathsAndHandlesCollisions() async throws {
        let w = try await makeWorld()
        let redundant = try await groups(w.db)[0].members.first { $0.relativePath == "B/kick.wav" }!
        let dest = w.root.appending(path: "A")   // already has kick.wav → collision
        let results = await w.op.perform(.move(destination: dest), on: [redundant])
        #expect(results[0].succeeded)
        #expect(results[0].destination?.lastPathComponent == "kick (2).wav")
        let row = try await w.db.reader.read { try Row.fetchOne($0, sql: "SELECT relativePath, parentDir, filename, status FROM sample WHERE id = ?", arguments: [redundant.id]) }!
        #expect(row["relativePath"] == "A/kick (2).wav")
        #expect(row["parentDir"] == "A")
        #expect(row["filename"] == "kick (2).wav")
        #expect(row["status"] == "present")
    }

    @Test func moveOutsideRootMarksMissing() async throws {
        let w = try await makeWorld()
        let redundant = try await groups(w.db)[0].members[1]
        let elsewhere = w.root.deletingLastPathComponent().appending(path: "Elsewhere")
        let results = await w.op.perform(.move(destination: elsewhere), on: [redundant])
        #expect(results[0].succeeded)
        #expect(FileManager.default.fileExists(atPath: elsewhere.appending(path: "kick.wav").path))
        let status = try await w.db.reader.read { try String.fetchOne($0, sql: "SELECT status FROM sample WHERE id = ?", arguments: [redundant.id]) }
        #expect(status == "missing")
    }

    /// Moving a sample from one indexed root into a folder inside *another* indexed root re-paths
    /// the row onto that root — it must not be marked missing just because the destination root
    /// held no source file.
    @Test func moveIntoAnotherRootRepaths() async throws {
        let base = try Fixtures.tempDir()
        let rootA = base.appending(path: "PackA")
        let rootB = base.appending(path: "PackB")
        for d in [rootA.appending(path: "Kicks"), rootB.appending(path: "Incoming")] {
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
        try Fixtures.writeTone(to: rootA.appending(path: "Kicks/kick.wav"))

        let db = try AppDatabase.inMemory()
        let (sampleId, idB): (Int64, Int64) = try await db.writer.write { d in
            var a = Root(name: "PackA", bookmarkData: Data(), lastResolvedPath: rootA.path, volumeUUID: nil)
            try a.insert(d)
            var b = Root(name: "PackB", bookmarkData: Data(), lastResolvedPath: rootB.path, volumeUUID: nil)
            try b.insert(d)
            let url = rootA.appending(path: "Kicks/kick.wav")
            let v = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            var s = Sample(rootId: a.id!, relativePath: "Kicks/kick.wav", fileSize: Int64(v.fileSize!), modifiedAt: v.contentModificationDate!)
            s.audioHash = AudioAnalyzer.analyze(url: url).audioHash
            s.indexedAt = Date()
            try s.insert(d)
            return (s.id!, b.id!)
        }

        let urls: [Int64: URL] = try await db.reader.read { d in
            Dictionary(uniqueKeysWithValues: try Root.fetchAll(d).map { ($0.id!, $0.id! == idB ? rootB : rootA) })
        }
        let op = FileOperator(database: db, fs: FakeFS(trashDir: base.appending(path: "Trash")),
                              resolveRoot: { urls[$0.id!]! })
        let results = await op.perform(.move(destination: rootB.appending(path: "Incoming")), on: [
            try await db.reader.read { try SampleRow.fetchOne($0, sql: "SELECT * FROM sample_with_annotation WHERE id = ?", arguments: [sampleId]) }!
        ])

        #expect(results[0].succeeded)
        let row = try await db.reader.read { try Row.fetchOne($0, sql: "SELECT rootId, relativePath, parentDir, status FROM sample WHERE id = ?", arguments: [sampleId]) }!
        #expect(row["rootId"] == idB)
        #expect(row["relativePath"] == "Incoming/kick.wav")
        #expect(row["parentDir"] == "Incoming")
        #expect(row["status"] == "present")
    }
}
