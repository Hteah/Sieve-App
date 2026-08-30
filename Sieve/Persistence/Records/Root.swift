import Foundation
import GRDB

struct Root: Codable, Identifiable, Hashable, Sendable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "root"

    var id: Int64?
    var name: String
    var bookmarkData: Data
    var lastResolvedPath: String
    var volumeUUID: String?
    var isAvailable: Bool
    var lastScanStarted: Date?
    var lastScanCompleted: Date?
    var fileCount: Int
    var createdAt: Date

    init(name: String, bookmarkData: Data, lastResolvedPath: String, volumeUUID: String?) {
        self.name = name
        self.bookmarkData = bookmarkData
        self.lastResolvedPath = lastResolvedPath
        self.volumeUUID = volumeUUID
        self.isAvailable = true
        self.fileCount = 0
        self.createdAt = Date()
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    static let samples = hasMany(Sample.self)
}
