import Foundation
import GRDB
import Testing
@testable import Sieve

struct FolderDuplicatesTests {
    /// A/1 == A/Sub/2 (both inside A), A/3 == B/4 (one inside A), B/5 == B/6 (none inside A).
    private func makeDB() async throws -> (AppDatabase, Int64) {
        let db = try AppDatabase.inMemory()
        let rootId: Int64 = try await db.writer.write { d in
            var r = Root(name: "Root", bookmarkData: Data(), lastResolvedPath: "/tmp/Root", volumeUUID: nil)
            try r.insert(d)
            let files = [("A/1.wav", "x"), ("A/Sub/2.wav", "x"), ("A/3.wav", "y"), ("B/4.wav", "y"),
                         ("B/5.wav", "z"), ("B/6.wav", "z")]
            for (rel, hash) in files {
                var s = Sample(rootId: r.id!, relativePath: rel, fileSize: 10, modifiedAt: .init(), createdAt: .init())
                s.audioHash = hash; s.indexedAt = Date()
                try s.insert(d)
            }
            return r.id!
        }
        return (db, rootId)
    }

    private func names(_ groups: [DuplicateGroup]) -> Set<Set<String>> {
        Set(groups.map { Set($0.members.map(\.relativePath)) })
    }

    @Test func folderOnlyCountsCopiesInsideTheFolder() async throws {
        let (db, rootId) = try await makeDB()
        let g = try await db.reader.read {
            try DuplicateFinder.groups(db: $0, in: .init(rootId: rootId, parentDir: "A", includeElsewhere: false))
        }
        #expect(names(g) == [["A/1.wav", "A/Sub/2.wav"]])
    }

    @Test func includeElsewhereAddsGroupsTouchingTheFolder() async throws {
        let (db, rootId) = try await makeDB()
        let g = try await db.reader.read {
            try DuplicateFinder.groups(db: $0, in: .init(rootId: rootId, parentDir: "A", includeElsewhere: true))
        }
        #expect(names(g) == [["A/1.wav", "A/Sub/2.wav"], ["A/3.wav", "B/4.wav"]])
    }

    @Test func wholeRootAndLibraryWide() async throws {
        let (db, rootId) = try await makeDB()
        let root = try await db.reader.read {
            try DuplicateFinder.groups(db: $0, in: .init(rootId: rootId, parentDir: "", includeElsewhere: false))
        }
        #expect(root.count == 3)
        let all = try await db.reader.read { try DuplicateFinder.groups(db: $0) }
        #expect(all.count == 3)
    }
}
