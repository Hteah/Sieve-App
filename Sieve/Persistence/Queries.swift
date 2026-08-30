import Foundation
import GRDB

enum SampleSort: String, CaseIterable, Sendable, Identifiable {
    case name, path, duration, size, modified, rating, peak
    var id: String { rawValue }
    var label: String {
        switch self {
        case .name: "Name"
        case .path: "Path"
        case .duration: "Duration"
        case .size: "Size"
        case .modified: "Modified"
        case .rating: "Rating"
        case .peak: "Peak level"
        }
    }
    var sqlOrder: String {
        switch self {
        case .name: "filename COLLATE NOCASE ASC, relativePath ASC"
        case .path: "rootId ASC, relativePath COLLATE NOCASE ASC"
        case .duration: "durationSec IS NULL, durationSec ASC"
        case .size: "fileSize DESC"
        case .modified: "modifiedAt DESC"
        case .rating: "COALESCE(rating,0) DESC, filename COLLATE NOCASE ASC"
        case .peak: "peakDb IS NULL, peakDb DESC"
        }
    }
}

/// Which sidebar item is selected. Drives the base query.
enum LibraryScope: Hashable, Sendable {
    case all
    case favorites
    case missing
    case duplicates
    case root(Int64)
    case folder(rootId: Int64, parentDir: String)
    case tag(Int64)
}

struct SampleFilter: Hashable, Sendable {
    var scope: LibraryScope = .all
    var searchText: String = ""
    var minRating: Int = 0
    var extensions: Set<String> = []
    var sort: SampleSort = .name
}

enum Queries {
    static let audioExtensions: [String] = ["wav", "aif", "aiff", "aifc", "flac", "mp3", "m4a", "aac", "caf"]

    /// Builds the SQL for the library table from a filter. Reads from the `sample_with_annotation` view.
    static func request(for filter: SampleFilter) -> SQLRequest<SampleRow> {
        var wheres: [SQL] = []
        var joins: SQL = ""

        switch filter.scope {
        case .all:
            wheres.append("status != 'unavailable'")
        case .favorites:
            wheres.append("isFavorite = 1")
        case .missing:
            wheres.append("status != 'present'")
        case .duplicates:
            wheres.append("""
                status = 'present' AND COALESCE(audioHash, fileHash) IN (
                    SELECT COALESCE(audioHash, fileHash) FROM sample
                    WHERE status = 'present' AND COALESCE(audioHash, fileHash) IS NOT NULL
                    GROUP BY COALESCE(audioHash, fileHash) HAVING COUNT(*) > 1)
                """)
        case .root(let rootId):
            wheres.append("rootId = \(rootId)")
        case .folder(let rootId, let parentDir):
            wheres.append("rootId = \(rootId) AND (parentDir = \(parentDir) OR parentDir LIKE \(parentDir + "/%"))")
        case .tag(let tagId):
            wheres.append("annotationId IN (SELECT annotationId FROM annotation_tag WHERE tagId = \(tagId))")
        }

        if filter.minRating > 0 {
            wheres.append("COALESCE(rating, 0) >= \(filter.minRating)")
        }
        if !filter.extensions.isEmpty {
            let exts = filter.extensions.sorted()
            wheres.append("ext IN \(exts)")
        }
        let trimmed = filter.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let pattern = ftsPattern(trimmed)
            joins = "JOIN sample_fts ON sample_fts.rowid = v.id AND sample_fts MATCH \(pattern)"
        }

        let whereClause: SQL = wheres.isEmpty ? "" : "WHERE " + wheres.joined(separator: " AND ")
        let order = SQL(sql: "ORDER BY " + filter.sort.sqlOrder)
        return SQLRequest<SampleRow>(literal: """
            SELECT v.* FROM sample_with_annotation v \(joins) \(whereClause) \(order)
            """)
    }

    /// Turn free text into a prefix-matching FTS5 query: each token becomes `"tok"*`.
    static func ftsPattern(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace })
            .map { token in
                let cleaned = token.replacingOccurrences(of: "\"", with: "")
                return "\"\(cleaned)\"*"
            }
            .joined(separator: " ")
    }

    // MARK: - Folder tree

    struct FolderNode: Identifiable, Hashable, Sendable {
        var rootId: Int64
        var path: String          // relative dir path, "" = root
        var name: String
        var children: [FolderNode]
        var id: String { "\(rootId):\(path)" }
    }

    /// Builds a folder tree for a root from the distinct parentDir values.
    static func folderTree(db: Database, rootId: Int64) throws -> [FolderNode] {
        let dirs = try String.fetchAll(db, sql: """
            SELECT DISTINCT parentDir FROM sample WHERE rootId = ? AND parentDir != '' ORDER BY parentDir
            """, arguments: [rootId])
        // Build nested structure.
        final class Builder {
            var children: [String: Builder] = [:]
            var order: [String] = []
        }
        let top = Builder()
        for dir in dirs {
            var node = top
            for comp in dir.split(separator: "/") {
                let key = String(comp)
                if let existing = node.children[key] {
                    node = existing
                } else {
                    let b = Builder()
                    node.children[key] = b
                    node.order.append(key)
                    node = b
                }
            }
        }
        func emit(_ b: Builder, prefix: String) -> [FolderNode] {
            b.order.map { name in
                let path = prefix.isEmpty ? name : prefix + "/" + name
                return FolderNode(rootId: rootId, path: path, name: name,
                                  children: emit(b.children[name]!, prefix: path))
            }
        }
        return emit(top, prefix: "")
    }

    // MARK: - Annotations

    /// Find or create the annotation for a sample.
    static func annotation(db: Database, for sample: SampleRow, create: Bool) throws -> Annotation? {
        if let hash = sample.contentHash {
            if let a = try Annotation.filter(Column("contentHash") == hash).fetchOne(db) { return a }
            guard create else { return nil }
            var a = Annotation(contentHash: hash, rootId: sample.rootId, relativePath: sample.relativePath)
            try a.insert(db)
            return a
        } else {
            let req = Annotation.filter(Column("contentHash") == nil && Column("rootId") == sample.rootId && Column("relativePath") == sample.relativePath)
            if let a = try req.fetchOne(db) { return a }
            guard create else { return nil }
            var a = Annotation(contentHash: nil, rootId: sample.rootId, relativePath: sample.relativePath)
            try a.insert(db)
            return a
        }
    }

    struct TagCount: Identifiable, Hashable, Sendable, FetchableRecord, Decodable {
        var id: Int64
        var name: String
        var colorHex: String?
        var count: Int
    }

    static func tagCounts(db: Database) throws -> [TagCount] {
        try TagCount.fetchAll(db, sql: """
            SELECT t.id, t.name, t.colorHex,
                   (SELECT COUNT(*) FROM annotation_tag at WHERE at.tagId = t.id) AS count
            FROM tag t ORDER BY t.name COLLATE NOCASE
            """)
    }
}
