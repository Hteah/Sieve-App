import Foundation
import GRDB

/// Cleans up after files renamed or moved outside Sieve (e.g. in RNMR): a rescan adds the new name as a new
/// row and marks the old one `missing`, which showed as a ⚠ row that won't play next to the same audio under
/// its new name (Long iVCS3, 2026-10-07). After the rescan has hashed the new files, a missing row whose audio
/// is still present in the same folder is that file under another name, so the stale row goes. Ratings,
/// tags and notes are keyed by content hash, so they carry over to the new name untouched.
///
/// Only within one root: a missing file whose audio exists in some other folder is still reported missing.
/// Rows are matched on `audioHash` (or `fileHash` when neither could be decoded).
enum RenameReconciler {
    /// Deletes the stale rows; returns how many.
    @discardableResult
    static func dropRenamedMissing(db: Database, rootId: Int64) throws -> Int {
        try db.execute(sql: """
            DELETE FROM sample
            WHERE rootId = ? AND status = 'missing'
              AND (
                (audioHash IS NOT NULL AND EXISTS (
                    SELECT 1 FROM sample p
                    WHERE p.rootId = sample.rootId AND p.status = 'present' AND p.audioHash = sample.audioHash))
                OR
                (audioHash IS NULL AND fileHash IS NOT NULL AND EXISTS (
                    SELECT 1 FROM sample p
                    WHERE p.rootId = sample.rootId AND p.status = 'present' AND p.audioHash IS NULL
                      AND p.fileHash = sample.fileHash))
              )
            """, arguments: [rootId])
        return db.changesCount
    }
}
