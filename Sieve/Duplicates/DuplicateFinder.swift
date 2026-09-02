import Foundation
import GRDB

struct DuplicateGroup: Identifiable, Hashable, Sendable {
    var hash: String
    var members: [SampleRow]
    var id: String { hash }
    var wastedBytes: Int64 { members.dropFirst().reduce(0) { $0 + $1.fileSize } }
}

enum DuplicateFinder {
    /// Groups present samples by content hash (audio hash preferred, file hash fallback), largest waste first.
    static func groups(db: Database) throws -> [DuplicateGroup] {
        let rows = try SampleRow.fetchAll(db, sql: """
            SELECT * FROM sample_with_annotation
            WHERE status = 'present' AND COALESCE(audioHash, fileHash) IN (
                SELECT COALESCE(audioHash, fileHash) FROM sample
                WHERE status = 'present' AND COALESCE(audioHash, fileHash) IS NOT NULL
                GROUP BY COALESCE(audioHash, fileHash) HAVING COUNT(*) > 1)
            ORDER BY relativePath
            """)
        var byHash: [String: [SampleRow]] = [:]
        for r in rows { if let h = r.contentHash { byHash[h, default: []].append(r) } }
        return byHash.map { DuplicateGroup(hash: $0.key, members: $0.value) }
            .sorted { $0.wastedBytes != $1.wastedBytes ? $0.wastedBytes > $1.wastedBytes : $0.hash < $1.hash }
    }
}
