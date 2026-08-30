import Foundation
import GRDB
import Testing
@testable import Sieve

struct DatabaseTests {
    func makeDB() throws -> AppDatabase { try AppDatabase.inMemory() }

    func seed(_ db: AppDatabase) async throws -> Int64 {
        try await db.writer.write { d in
            var root = Root(name: "Pack", bookmarkData: Data(), lastResolvedPath: "/x", volumeUUID: nil)
            try root.insert(d)
            let now = Date()
            for (path, hash) in [("Kicks/Big Kick.wav", "h1"), ("Kicks/Sub/Deep Kick.wav", "h1"), ("Snares/Snap.wav", "h2"), ("Hats/Open.aif", "h3")] {
                var s = Sample(rootId: root.id!, relativePath: path, fileSize: 100, modifiedAt: now)
                s.audioHash = hash
                s.indexedAt = now
                try s.insert(d)
            }
            return root.id!
        }
    }

    @Test func ftsSearchAndFilters() async throws {
        let db = try makeDB()
        let rootId = try await seed(db)

        func fetch(_ f: SampleFilter) async throws -> [SampleRow] {
            let req = Queries.request(for: f)
            return try await db.reader.read { try req.fetchAll($0) }
        }
        #expect(try await fetch(SampleFilter(searchText: "kick")).count == 2)
        #expect(try await fetch(SampleFilter(scope: .folder(rootId: rootId, parentDir: "Kicks"))).count == 2)   // includes nested Sub/
        #expect(try await Set(fetch(SampleFilter(scope: .duplicates)).map(\.audioHash)) == ["h1"])
        #expect(try await fetch(SampleFilter(extensions: ["aif"])).map(\.filename) == ["Open.aif"])
    }

    @Test func folderTreeNests() async throws {
        let db = try makeDB()
        let rootId = try await seed(db)
        let tree = try await db.reader.read { try Queries.folderTree(db: $0, rootId: rootId) }
        #expect(tree.map(\.name) == ["Hats", "Kicks", "Snares"])
        #expect(tree[1].children.map(\.path) == ["Kicks/Sub"])
    }

    @Test func annotationsAreSharedByContentHashAndSurviveMoves() async throws {
        let db = try makeDB()
        _ = try await seed(db)
        let store = AnnotationStore(database: db)
        var rows = try await db.reader.read { try Queries.request(for: SampleFilter()).fetchAll($0) }
        let big = try #require(rows.first { $0.filename == "Big Kick.wav" })
        try await store.setRating(4, for: big)
        try await store.addTag(named: "kick", to: [big])
        try await store.setFavorite(true, for: big)

        rows = try await db.reader.read { try Queries.request(for: SampleFilter()).fetchAll($0) }
        let deep = try #require(rows.first { $0.filename == "Deep Kick.wav" })
        #expect(deep.rating == 4)            // same audio hash → shared annotation
        #expect(deep.tags == ["kick"])

        // Simulate a move: path changes, hash stays.
        try await db.writer.write { d in
            try d.execute(sql: "UPDATE sample SET relativePath = 'Moved/Big Kick.wav', parentDir = 'Moved' WHERE id = ?", arguments: [big.id])
        }
        rows = try await db.reader.read { try Queries.request(for: SampleFilter(scope: .favorites)).fetchAll($0) }
        #expect(rows.map(\.filename).sorted() == ["Big Kick.wav", "Deep Kick.wav"])

        let tags = try await db.reader.read { try Queries.tagCounts(db: $0) }
        #expect(tags.map(\.name) == ["kick"] && tags[0].count == 1)

        let ratedReq = Queries.request(for: SampleFilter(minRating: 4))
        #expect(try await db.reader.read { try ratedReq.fetchAll($0) }.count == 2)
    }
}
