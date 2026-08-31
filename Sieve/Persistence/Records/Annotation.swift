import Foundation
import GRDB

struct Tag: Codable, Identifiable, Hashable, Sendable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "tag"
    var id: Int64?
    var name: String
    var colorHex: String?
    var createdAt: Date

    init(name: String, colorHex: String? = nil) {
        self.name = name
        self.colorHex = colorHex
        self.createdAt = Date()
    }

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// User data attached to content. Keyed by content hash when available so it follows files
/// across moves/renames; falls back to (rootId, relativePath) for files that couldn't be hashed.
struct Annotation: Codable, Identifiable, Hashable, Sendable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "annotation"
    var id: Int64?
    var contentHash: String?
    var rootId: Int64?
    var relativePath: String?
    var rating: Int
    var isFavorite: Bool
    var notes: String
    /// 6-bit mask of applied Quick Tags (bit i ⇒ slot i). See `QuickTags`.
    var quickTags: Int
    var updatedAt: Date

    init(contentHash: String?, rootId: Int64?, relativePath: String?) {
        self.contentHash = contentHash
        self.rootId = rootId
        self.relativePath = relativePath
        self.rating = 0
        self.isFavorite = false
        self.notes = ""
        self.quickTags = 0
        self.updatedAt = Date()
    }

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    static let tags = hasMany(AnnotationTag.self)
}

struct AnnotationTag: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "annotation_tag"
    var annotationId: Int64
    var tagId: Int64
}

struct FileOpLog: Codable, Identifiable, Hashable, Sendable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "file_op_log"
    var id: Int64?
    var sampleId: Int64?
    var rootId: Int64
    var relativePath: String
    var op: String          // "trash" | "move" | "delete"
    var destinationPath: String?
    var performedAt: Date
    var succeeded: Bool
    var error: String?

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}
