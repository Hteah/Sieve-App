import Foundation
import GRDB
import Testing
@testable import Sieve

struct FolderGroupTests {
    private func makeWorld() async throws -> (db: AppDatabase, store: FolderGroupStore, rootA: Int64, rootB: Int64) {
        let db = try AppDatabase.inMemory()
        let (a, b): (Int64, Int64) = try await db.writer.write { d in
            var ra = Root(name: "A", bookmarkData: Data(), lastResolvedPath: "/a", volumeUUID: nil)
            var rb = Root(name: "B", bookmarkData: Data(), lastResolvedPath: "/b", volumeUUID: nil)
            try ra.insert(d); try rb.insert(d)
            let now = Date()
            for (rid, name) in [(ra.id!, "a1.wav"), (ra.id!, "a2.wav"), (rb.id!, "b1.wav")] {
                var s = Sample(rootId: rid, relativePath: name, fileSize: 1, modifiedAt: now)
                s.audioHash = name; s.indexedAt = now
                try s.insert(d)
            }
            return (ra.id!, rb.id!)
        }
        return (db, FolderGroupStore(database: db), a, b)
    }

    @Test func createRenameDelete() async throws {
        let w = try await makeWorld()
        let gid = try await w.store.create(name: "  Drums  ")
        var groups = try await w.db.reader.read { try FolderGroup.fetchAll($0) }
        #expect(groups.count == 1 && groups[0].name == "Drums")

        try await w.store.rename(id: gid, to: "Percussion")
        try await w.store.assign(rootId: w.rootA, to: gid)
        let rootA = try await w.db.reader.read { try Root.fetchOne($0, key: w.rootA) }
        #expect(rootA?.groupId == gid)

        try await w.store.delete(id: gid)
        groups = try await w.db.reader.read { try FolderGroup.fetchAll($0) }
        #expect(groups.isEmpty)
        let rootAAfter = try await w.db.reader.read { try Root.fetchOne($0, key: w.rootA) }
        #expect(rootAAfter?.groupId == nil)          // FK onDelete: .setNull
    }

    @Test func emptyNameRejected() async throws {
        let w = try await makeWorld()
        await #expect(throws: FolderGroupStore.StoreError.self) { try await w.store.create(name: "   ") }
    }

    @Test func groupScopeFiltersToItsRoots() async throws {
        let w = try await makeWorld()
        let gid = try await w.store.create(name: "G")
        try await w.store.assign(rootId: w.rootA, to: gid)

        let req = Queries.request(for: SampleFilter(scope: .group(gid)))
        let rows = try await w.db.reader.read { try req.fetchAll($0) }
        #expect(Set(rows.map(\.filename)) == ["a1.wav", "a2.wav"])
    }
}
