import Foundation
import GRDB

/// Write-side helpers for folder groups and root membership. All go through the database writer.
struct FolderGroupStore: Sendable {
    let database: AppDatabase

    /// Creates a group after the last one and returns its id.
    @discardableResult
    func create(name: String) async throws -> Int64 {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw StoreError.emptyName }
        return try await database.writer.write { db in
            let maxOrder = try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(sortOrder), -1) FROM folder_group") ?? -1
            var group = FolderGroup(name: trimmed, sortOrder: maxOrder + 1)
            try group.insert(db)
            return group.id ?? 0
        }
    }

    func rename(id: Int64, to name: String) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw StoreError.emptyName }
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE folder_group SET name = ? WHERE id = ?", arguments: [trimmed, id])
        }
    }

    /// Deletes the group; its roots fall back to ungrouped via the `onDelete: .setNull` foreign key.
    func delete(id: Int64) async throws {
        _ = try await database.writer.write { db in try FolderGroup.deleteOne(db, key: id) }
    }

    /// Moves a root into `groupId` (nil = ungrouped).
    func assign(rootId: Int64, to groupId: Int64?) async throws {
        try await assign(rootIds: [rootId], to: groupId)
    }

    /// Moves several roots into `groupId` (nil = ungrouped) in one transaction.
    func assign(rootIds: [Int64], to groupId: Int64?) async throws {
        guard !rootIds.isEmpty else { return }
        try await database.writer.write { db in
            for id in rootIds {
                try db.execute(sql: "UPDATE root SET groupId = ? WHERE id = ?", arguments: [groupId, id])
            }
        }
    }

    enum StoreError: Error { case emptyName }
}
