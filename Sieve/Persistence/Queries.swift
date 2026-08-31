import Foundation
import GRDB

enum SampleSort: String, CaseIterable, Sendable, Identifiable {
    case name, path, duration, size, modified, rating, rate, bits, format
    var id: String { rawValue }
    var label: String {
        switch self {
        case .name: "Name"
        case .path: "Path"
        case .duration: "Duration"
        case .size: "Size"
        case .modified: "Modified"
        case .rating: "Rating"
        case .rate: "Sample rate"
        case .bits: "Bit depth"
        case .format: "Format"
        }
    }

    /// Primary sort expression.
    private var key: String {
        switch self {
        case .name: "filename COLLATE NOCASE"
        case .path: "relativePath COLLATE NOCASE"
        case .duration: "durationSec"
        case .size: "fileSize"
        case .modified: "modifiedAt"
        case .rating: "COALESCE(rating, 0)"
        case .rate: "sampleRate"
        case .bits: "bitDepth"
        case .format: "ext COLLATE NOCASE"
        }
    }

    /// Sorts whose column can be NULL — those rows sort last regardless of direction.
    private var nullable: Bool {
        switch self {
        case .name, .path, .rating, .format: false
        case .duration, .size, .modified, .rate, .bits: true
        }
    }

    /// The direction to snap to when the user first switches to this sort.
    var defaultAscending: Bool {
        switch self {
        case .name, .path, .rate, .bits, .format: true
        case .duration, .size, .modified, .rating: false   // duration: longest first
        }
    }

    func sqlOrder(ascending: Bool) -> String {
        let dir = ascending ? "ASC" : "DESC"
        var parts: [String] = []
        if nullable { parts.append("\(key) IS NULL") }
        parts.append("\(key) \(dir)")
        if self != .name, self != .path {
            parts.append("filename COLLATE NOCASE ASC, relativePath ASC")
        }
        return parts.joined(separator: ", ")
    }

    /// In-memory equivalent of `sqlOrder`, so a sort-field or direction change can reorder the
    /// rows already loaded instead of re-querying and re-decoding the whole table. NULLs sort
    /// last in both directions; `id` is the final tie-breaker (cheap and stable — no string
    /// compare in the hot path, where ties are common for rate/bit-depth sorts).
    func rowsAreInOrder(_ a: SampleRow, _ b: SampleRow, ascending: Bool) -> Bool {
        switch self {
        case .name:
            let r = a.filename.localizedCaseInsensitiveCompare(b.filename)
            return r == .orderedSame ? a.id < b.id : ascending == (r == .orderedAscending)
        case .path:
            let r = a.relativePath.localizedCaseInsensitiveCompare(b.relativePath)
            return r == .orderedSame ? a.id < b.id : ascending == (r == .orderedAscending)
        case .duration:
            return Self.orderOptional(a.durationSec, b.durationSec, ascending: ascending, aId: a.id, bId: b.id)
        case .size:
            return a.fileSize == b.fileSize ? a.id < b.id : ascending == (a.fileSize < b.fileSize)
        case .modified:
            return a.modifiedAt == b.modifiedAt ? a.id < b.id : ascending == (a.modifiedAt < b.modifiedAt)
        case .rating:
            let ra = a.rating ?? 0, rb = b.rating ?? 0
            return ra == rb ? a.id < b.id : ascending == (ra < rb)
        case .rate:
            return Self.orderOptional(a.sampleRate, b.sampleRate, ascending: ascending, aId: a.id, bId: b.id)
        case .bits:
            return Self.orderOptional(a.bitDepth, b.bitDepth, ascending: ascending, aId: a.id, bId: b.id)
        case .format:
            let r = a.ext.localizedCaseInsensitiveCompare(b.ext)
            return r == .orderedSame ? a.id < b.id : ascending == (r == .orderedAscending)
        }
    }

    private static func orderOptional<T: Comparable>(_ x: T?, _ y: T?, ascending: Bool, aId: Int64, bId: Int64) -> Bool {
        switch (x, y) {
        case let (x?, y?): return x == y ? aId < bId : ascending == (x < y)
        case (nil, nil): return aId < bId
        case (nil, _): return false   // unknown value sorts last, whichever direction
        case (_, nil): return true
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
    case group(Int64)
    case tag(Int64)
    case quickTag(Int)     // Quick Tag slot index 0..<QuickTags.count
}

struct SampleFilter: Hashable, Sendable {
    var scope: LibraryScope = .all
    var searchText: String = ""
    var minRating: Int = 0
    var extensions: Set<String> = []
    var sort: SampleSort = .name
    var sortAscending: Bool = true

    /// Switch sort field and snap the direction to that field's natural default.
    mutating func select(_ newSort: SampleSort) {
        sort = newSort
        sortAscending = newSort.defaultAscending
    }

    /// True when everything that shapes the query result set (not its order) is unchanged.
    func samePredicate(as other: SampleFilter) -> Bool {
        scope == other.scope
            && searchText == other.searchText
            && minRating == other.minRating
            && extensions == other.extensions
    }
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
        case .group(let groupId):
            wheres.append("status != 'unavailable' AND rootId IN (SELECT id FROM root WHERE groupId = \(groupId))")
        case .tag(let tagId):
            wheres.append("annotationId IN (SELECT annotationId FROM annotation_tag WHERE tagId = \(tagId))")
        case .quickTag(let index):
            wheres.append("status != 'unavailable' AND (COALESCE(quickTags, 0) & \(QuickTags.mask(index))) != 0")
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
        let order = SQL(sql: "ORDER BY " + filter.sort.sqlOrder(ascending: filter.sortAscending))
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

    /// Number of annotations carrying each Quick Tag, indexed 0..<QuickTags.count.
    static func quickTagCounts(db: Database) throws -> [Int] {
        var counts = [Int](repeating: 0, count: QuickTags.count)
        for mask in try Int.fetchAll(db, sql: "SELECT quickTags FROM annotation WHERE quickTags != 0") {
            for i in 0..<QuickTags.count where mask & QuickTags.mask(i) != 0 {
                counts[i] += 1
            }
        }
        return counts
    }
}
