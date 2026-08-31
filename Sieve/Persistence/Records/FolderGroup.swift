import Foundation
import GRDB

/// A user-named collection of indexed folders (`root`s). A root's `groupId` points here; nil = ungrouped.
struct FolderGroup: Codable, Identifiable, Hashable, Sendable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "folder_group"

    var id: Int64?
    var name: String
    var sortOrder: Int
    var createdAt: Date

    init(name: String, sortOrder: Int = 0) {
        self.name = name
        self.sortOrder = sortOrder
        self.createdAt = Date()
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    static let roots = hasMany(Root.self)
}
