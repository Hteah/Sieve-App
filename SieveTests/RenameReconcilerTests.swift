import Foundation
import GRDB
import Testing
@testable import Sieve

struct RenameReconcilerTests {
    /// Rows: (root index, path, status, audioHash, fileHash).
    private func makeDB(_ rows: [(Int, String, SampleStatus, String?, String?)]) async throws -> (AppDatabase, [Int64]) {
        let db = try AppDatabase.inMemory()
        let roots: [Int64] = try await db.writer.write { d in
            var ids: [Int64] = []
            for name in ["A", "B"] {
                var r = Root(name: name, bookmarkData: Data(), lastResolvedPath: "/tmp/\(name)", volumeUUID: nil)
                try r.insert(d)
                ids.append(r.id!)
            }
            for (root, path, status, audio, file) in rows {
                var s = Sample(rootId: ids[root], relativePath: path, fileSize: 10, modifiedAt: .init(), createdAt: .init())
                s.status = status; s.audioHash = audio; s.fileHash = file; s.indexedAt = Date()
                try s.insert(d)
            }
            return ids
        }
        return (db, roots)
    }

    private func paths(_ db: AppDatabase) async throws -> [String] {
        try await db.reader.read { d in try String.fetchAll(d, sql: "SELECT relativePath FROM sample ORDER BY relativePath") }
    }

    @Test func aRenamedFilesStaleRowGoes() async throws {
        let (db, roots) = try await makeDB([
            (0, "OutRec[18.06.2014][00:21:49].wav", .missing, "h1", "f1"),
            (0, "18.06.2014 Vsc3 Squeeel.wav", .present, "h1", "f1"),
            (0, "Sub/Moved.wav", .present, "h2", "f2"),
            (0, "Old Place.wav", .missing, "h2", "f2"),   // moved into a sub-folder
        ])
        let n = try await db.writer.write { try RenameReconciler.dropRenamedMissing(db: $0, rootId: roots[0]) }
        #expect(n == 2)
        #expect(try await paths(db) == ["18.06.2014 Vsc3 Squeeel.wav", "Sub/Moved.wav"])
    }

    @Test func reallyMissingFilesAndOtherFoldersAreLeftAlone() async throws {
        let (db, roots) = try await makeDB([
            (0, "Gone.wav", .missing, "h1", "f1"),            // no copy anywhere: still missing
            (0, "Copy elsewhere.wav", .missing, "h2", "f2"),  // its audio is only in root B
            (1, "In B.wav", .present, "h2", "f2"),
            (0, "Unhashed.wav", .missing, nil, nil),          // never analysed
            (0, "Unavailable.wav", .unavailable, "h3", "f3"), // drive unplugged: not "missing"
            (0, "Present.wav", .present, "h3", "f3"),
        ])
        let n = try await db.writer.write { try RenameReconciler.dropRenamedMissing(db: $0, rootId: roots[0]) }
        #expect(n == 0)
        #expect(try await paths(db).count == 6)
    }

    @Test func undecodableFilesMatchByFileHash() async throws {
        let (db, roots) = try await makeDB([
            (0, "old.mp3", .missing, nil, "f9"),
            (0, "new.mp3", .present, nil, "f9"),
        ])
        #expect(try await db.writer.write { try RenameReconciler.dropRenamedMissing(db: $0, rootId: roots[0]) } == 1)
        #expect(try await paths(db) == ["new.mp3"])
    }

    @Test func ratingsFollowTheNewName() async throws {
        let (db, roots) = try await makeDB([
            (0, "Recorded Audio(4).wav", .missing, "h1", "f1"),
            (0, "Open the Door.wav", .present, "h1", "f1"),
        ])
        try await db.writer.write { d in
            try d.execute(sql: "INSERT INTO annotation (contentHash, rating, updatedAt) VALUES ('h1', 4, CURRENT_TIMESTAMP)")
            try RenameReconciler.dropRenamedMissing(db: d, rootId: roots[0])
        }
        let rating = try await db.reader.read { d in
            try Int.fetchOne(d, sql: "SELECT rating FROM sample_with_annotation WHERE relativePath = 'Open the Door.wav'")
        }
        #expect(rating == 4)
    }
}
