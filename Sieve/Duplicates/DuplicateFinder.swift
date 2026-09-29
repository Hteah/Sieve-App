import Foundation
import GRDB

struct DuplicateGroup: Identifiable, Hashable, Sendable {
    var hash: String
    var members: [SampleRow]
    var id: String { hash }
    var wastedBytes: Int64 { members.dropFirst().reduce(0) { $0 + $1.fileSize } }
}

enum DuplicateFinder {
    /// Where to look for duplicates. `folder` limits it to one folder (sub-folders included):
    /// with `includeElsewhere` false only copies that are all inside it count; true also takes in
    /// the folder's files whose other copy lives anywhere else in the library (all copies listed).
    struct Scope: Sendable {
        var rootId: Int64
        var parentDir: String
        var includeElsewhere: Bool
    }

    /// Groups present samples by content hash (audio hash preferred, file hash fallback), largest waste first.
    static func groups(db: Database, in scope: Scope? = nil) throws -> [DuplicateGroup] {
        // A folder-only search groups just that folder's rows; otherwise group across the library
        // and (for "include elsewhere") keep the groups with at least one member in the folder.
        let inFolder: SQL = scope.map { Queries.folderPredicate(rootId: $0.rootId, parentDir: $0.parentDir) } ?? "1"
        let candidates: SQL = scope?.includeElsewhere == false ? inFolder : "1"
        let rows = try SQLRequest<SampleRow>(literal: """
            SELECT * FROM sample_with_annotation
            WHERE status = 'present' AND \(candidates) AND COALESCE(audioHash, fileHash) IN (
                SELECT COALESCE(audioHash, fileHash) FROM sample
                WHERE status = 'present' AND \(candidates) AND COALESCE(audioHash, fileHash) IS NOT NULL
                GROUP BY COALESCE(audioHash, fileHash) HAVING COUNT(*) > 1)
            ORDER BY relativePath
            """).fetchAll(db)
        var byHash: [String: [SampleRow]] = [:]
        for r in rows { if let h = r.contentHash { byHash[h, default: []].append(r) } }
        if let scope, scope.includeElsewhere {
            let dir = scope.parentDir
            byHash = byHash.filter { _, members in
                members.contains { $0.rootId == scope.rootId
                    && (dir.isEmpty || $0.parentDir == dir || $0.parentDir.hasPrefix(dir + "/")) }
            }
        }
        return byHash.map { DuplicateGroup(hash: $0.key, members: $0.value) }
            .sorted { $0.wastedBytes != $1.wastedBytes ? $0.wastedBytes > $1.wastedBytes : $0.hash < $1.hash }
    }
}
