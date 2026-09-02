import Foundation
import GRDB
import Testing
@testable import Sieve

struct RootRelinkTests {
    private func makeScanner() throws -> (AppDatabase, ScanCoordinator) {
        let db = try AppDatabase.inMemory()
        return (db, ScanCoordinator(database: db, bookmarks: BookmarkStore()))
    }

    /// The DB half of a relink swaps the bookmark/path/volume and keeps every identity + stats field,
    /// and does not touch per-sample status (the follow-up scan owns that).
    @Test func applyRelinkSwapsLocationAndPreservesIdentity() async throws {
        let (db, scanner) = try makeScanner()

        let (rootId, groupId, createdAt): (Int64, Int64, Date) = try await db.writer.write { d in
            var group = FolderGroup(name: "Drives")
            try group.insert(d)
            var root = Root(name: "Pack", bookmarkData: Data([1, 2, 3]),
                            lastResolvedPath: "/Volumes/OldDrive/Pack", volumeUUID: "OLD-UUID")
            root.groupId = group.id
            root.fileCount = 42
            try root.insert(d)
            let now = Date()
            for path in ["Kicks/Big.wav", "Snares/Snap.wav"] {
                var s = Sample(rootId: root.id!, relativePath: path, fileSize: 100, modifiedAt: now)
                s.status = .unavailable
                s.indexedAt = now
                try s.insert(d)
            }
            return (root.id!, group.id!, root.createdAt)
        }

        try await scanner.applyRelink(id: rootId,
                                      newURL: URL(fileURLWithPath: "/Volumes/NewDrive/Relocated Pack"),
                                      bookmarkData: Data([9, 9, 9, 9]),
                                      volumeUUID: "NEW-UUID")

        let root = try #require(try await db.reader.read { try Root.fetchOne($0, key: rootId) })
        #expect(root.bookmarkData == Data([9, 9, 9, 9]))
        #expect(root.lastResolvedPath == "/Volumes/NewDrive/Relocated Pack")
        #expect(root.volumeUUID == "NEW-UUID")

        // Identity + stats untouched.
        #expect(root.id == rootId)
        #expect(root.name == "Pack")
        #expect(root.groupId == groupId)
        #expect(root.fileCount == 42)
        #expect(abs(root.createdAt.timeIntervalSince1970 - createdAt.timeIntervalSince1970) < 1)

        // Sample status is left for the scan to reconcile.
        let statuses = try await db.reader.read {
            try String.fetchAll($0, sql: "SELECT status FROM sample WHERE rootId = ?", arguments: [rootId])
        }
        #expect(statuses == ["unavailable", "unavailable"])
    }

    @Test func applyRelinkThrowsForUnknownRoot() async throws {
        let (_, scanner) = try makeScanner()
        await #expect(throws: ScanError.self) {
            try await scanner.applyRelink(id: 999, newURL: URL(fileURLWithPath: "/tmp/x"),
                                          bookmarkData: Data(), volumeUUID: nil)
        }
    }
}
