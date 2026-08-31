import Foundation
import GRDB

/// Write-side helpers for tags/ratings/notes. All go through the database writer.
struct AnnotationStore: Sendable {
    let database: AppDatabase

    func setRating(_ rating: Int, for sample: SampleRow) async throws {
        try await database.writer.write { db in
            guard var a = try Queries.annotation(db: db, for: sample, create: true) else { return }
            a.rating = max(0, min(5, rating)); a.updatedAt = Date()
            try a.update(db)
        }
    }

    func setFavorite(_ fav: Bool, for sample: SampleRow) async throws {
        try await database.writer.write { db in
            guard var a = try Queries.annotation(db: db, for: sample, create: true) else { return }
            a.isFavorite = fav; a.updatedAt = Date()
            try a.update(db)
        }
    }

    /// Toggle Quick Tag `index` on every given sample. For a mixed selection (some on, some off)
    /// all are driven to "on" — matching how `addTag` and the favorites menu resolve a mix. The
    /// on/off decision is taken from current on-disk state, not the (possibly stale) passed rows.
    func toggleQuickTag(_ index: Int, for samples: [SampleRow]) async throws {
        guard (0..<QuickTags.count).contains(index), !samples.isEmpty else { return }
        let bit = QuickTags.mask(index)
        try await database.writer.write { db in
            var annotations: [Annotation] = []
            for s in samples {
                if let a = try Queries.annotation(db: db, for: s, create: true) { annotations.append(a) }
            }
            let allOn = !annotations.isEmpty && annotations.allSatisfy { $0.quickTags & bit != 0 }
            for var a in annotations {
                a.quickTags = allOn ? (a.quickTags & ~bit) : (a.quickTags | bit)
                a.updatedAt = Date()
                try a.update(db)
            }
        }
    }

    /// Unconditionally add Quick Tag `index` to every given sample (used by drag-and-drop).
    func addQuickTag(_ index: Int, to samples: [SampleRow]) async throws {
        guard (0..<QuickTags.count).contains(index), !samples.isEmpty else { return }
        let bit = QuickTags.mask(index)
        try await database.writer.write { db in
            for s in samples {
                guard var a = try Queries.annotation(db: db, for: s, create: true) else { continue }
                guard a.quickTags & bit == 0 else { continue }
                a.quickTags |= bit
                a.updatedAt = Date()
                try a.update(db)
            }
        }
    }

    func setQuickTagMask(_ mask: Int, for sample: SampleRow) async throws {
        try await database.writer.write { db in
            guard var a = try Queries.annotation(db: db, for: sample, create: true) else { return }
            a.quickTags = mask; a.updatedAt = Date()
            try a.update(db)
        }
    }

    func setNotes(_ notes: String, for sample: SampleRow) async throws {
        try await database.writer.write { db in
            guard var a = try Queries.annotation(db: db, for: sample, create: true) else { return }
            a.notes = notes; a.updatedAt = Date()
            try a.update(db)
        }
    }

    func notes(for sample: SampleRow) async throws -> String {
        try await database.reader.read { db in
            try Queries.annotation(db: db, for: sample, create: false)?.notes ?? ""
        }
    }

    /// Adds a tag (creating it if needed) to every given sample.
    func addTag(named rawName: String, to samples: [SampleRow]) async throws {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        try await database.writer.write { db in
            var tag = try Tag.filter(Column("name") == name).fetchOne(db)
            if tag == nil {
                var t = Tag(name: name)
                try t.insert(db)
                tag = t
            }
            guard let tagId = tag?.id else { return }
            for s in samples {
                guard let a = try Queries.annotation(db: db, for: s, create: true), let aid = a.id else { continue }
                try db.execute(sql: "INSERT OR IGNORE INTO annotation_tag (annotationId, tagId) VALUES (?, ?)", arguments: [aid, tagId])
            }
        }
    }

    func removeTag(named name: String, from sample: SampleRow) async throws {
        try await database.writer.write { db in
            guard let tag = try Tag.filter(Column("name") == name).fetchOne(db), let tagId = tag.id,
                  let a = try Queries.annotation(db: db, for: sample, create: false), let aid = a.id else { return }
            try db.execute(sql: "DELETE FROM annotation_tag WHERE annotationId = ? AND tagId = ?", arguments: [aid, tagId])
        }
    }

    /// After a file's audio was rewritten (e.g. sample-rate / bit-depth conversion), its content
    /// hash changes. Give the new hash its own copy of the old hash's rating/favorite/notes/tags
    /// so annotations carry over. The original annotation is left intact for any identical copies
    /// that were not converted.
    func carryOverAnnotation(from oldHash: String, to newHash: String, rootId: Int64, relativePath: String) async throws {
        guard oldHash != newHash else { return }
        try await database.writer.write { db in
            guard let src = try Annotation.filter(Column("contentHash") == oldHash).fetchOne(db) else { return }
            guard try Annotation.filter(Column("contentHash") == newHash).fetchOne(db) == nil else { return }
            let tagIds = try Int64.fetchAll(db, sql: "SELECT tagId FROM annotation_tag WHERE annotationId = ?",
                                            arguments: [src.id ?? -1])
            guard src.rating != 0 || src.isFavorite || !src.notes.isEmpty || src.quickTags != 0 || !tagIds.isEmpty else { return }
            var dst = Annotation(contentHash: newHash, rootId: rootId, relativePath: relativePath)
            dst.rating = src.rating
            dst.isFavorite = src.isFavorite
            dst.notes = src.notes
            dst.quickTags = src.quickTags
            dst.updatedAt = Date()
            try dst.insert(db)
            if let did = dst.id {
                for tid in tagIds {
                    try db.execute(sql: "INSERT OR IGNORE INTO annotation_tag (annotationId, tagId) VALUES (?, ?)",
                                   arguments: [did, tid])
                }
            }
        }
    }

    func deleteTag(id: Int64) async throws {
        _ = try await database.writer.write { db in try Tag.deleteOne(db, key: id) }
    }

    func renameTag(id: Int64, to name: String) async throws {
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE tag SET name = ? WHERE id = ?", arguments: [name, id])
        }
    }
}
