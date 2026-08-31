import Foundation
import GRDB
import Testing
@testable import Sieve

struct QuickTagQueryTests {
    private func makeDB() throws -> AppDatabase { try AppDatabase.inMemory() }

    private func seed(_ db: AppDatabase) async throws {
        try await db.writer.write { d in
            var root = Root(name: "Pack", bookmarkData: Data(), lastResolvedPath: "/x", volumeUUID: nil)
            try root.insert(d)
            let now = Date()
            for (path, hash) in [("a.wav", "ha"), ("b.wav", "hb"), ("c.wav", "hc")] {
                var s = Sample(rootId: root.id!, relativePath: path, fileSize: 100, modifiedAt: now)
                s.audioHash = hash
                s.indexedAt = now
                try s.insert(d)
            }
        }
    }

    private func rows(_ db: AppDatabase, _ filter: SampleFilter) async throws -> [SampleRow] {
        try await db.reader.read { try Queries.request(for: filter).fetchAll($0) }
    }

    @Test func toggleQuickTagCreatesAnnotationAndFiltersByBit() async throws {
        let db = try makeDB()
        try await seed(db)
        let store = AnnotationStore(database: db)

        let all = try await rows(db, SampleFilter())
        let a = try #require(all.first { $0.filename == "a.wav" })
        let b = try #require(all.first { $0.filename == "b.wav" })

        try await store.toggleQuickTag(2, for: [a])
        try await store.toggleQuickTag(2, for: [b])
        try await store.toggleQuickTag(5, for: [b])

        let bit2 = try await rows(db, SampleFilter(scope: .quickTag(2))).map(\.filename).sorted()
        #expect(bit2 == ["a.wav", "b.wav"])
        let bit5 = try await rows(db, SampleFilter(scope: .quickTag(5))).map(\.filename)
        #expect(bit5 == ["b.wav"])

        try await store.toggleQuickTag(2, for: [a])   // toggle again → clears
        #expect(try await rows(db, SampleFilter(scope: .quickTag(2))).map(\.filename) == ["b.wav"])

        let counts = try await db.reader.read { try Queries.quickTagCounts(db: $0) }
        #expect(counts[2] == 1 && counts[5] == 1 && counts[0] == 0)
    }

    @Test func mixedSelectionDrivesAllOn() async throws {
        let db = try makeDB()
        try await seed(db)
        let store = AnnotationStore(database: db)
        let all = try await rows(db, SampleFilter())
        let a = try #require(all.first { $0.filename == "a.wav" })

        try await store.toggleQuickTag(1, for: [a])                  // only a has bit 1
        let mixed = try await rows(db, SampleFilter())
        let aRow = try #require(mixed.first { $0.filename == "a.wav" })
        let cRow = try #require(mixed.first { $0.filename == "c.wav" })
        try await store.toggleQuickTag(1, for: [aRow, cRow])         // mixed → both on

        #expect(try await rows(db, SampleFilter(scope: .quickTag(1))).map(\.filename).sorted() == ["a.wav", "c.wav"])
    }

    @Test func carryOverCopiesQuickTags() async throws {
        let db = try makeDB()
        try await seed(db)
        let store = AnnotationStore(database: db)
        let a = try #require(try await rows(db, SampleFilter()).first { $0.filename == "a.wav" })

        try await store.toggleQuickTag(3, for: [a])
        try await store.carryOverAnnotation(from: "ha", to: "hNEW", rootId: a.rootId, relativePath: a.relativePath)

        try await db.writer.write { d in
            try d.execute(sql: "UPDATE sample SET audioHash = 'hNEW' WHERE relativePath = 'a.wav'")
        }
        let moved = try await rows(db, SampleFilter(scope: .quickTag(3))).map(\.filename)
        #expect(moved == ["a.wav"])
    }
}
