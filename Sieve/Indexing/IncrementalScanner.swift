import Foundation

/// What the index already knows about a file (enough to detect changes).
struct IndexedEntry: Hashable, Sendable {
    var id: Int64
    var fileSize: Int64
    var modifiedAt: Date
    var status: SampleStatus
}

/// Pure diff between the index and what's on disk. No I/O, fully testable.
struct ScanDiff: Sendable, Equatable {
    var added: [FileEntry] = []
    var modified: [(id: Int64, entry: FileEntry)] = []
    var unchanged: [Int64] = []      // ids to touch lastSeenAt / flip back to present
    var removed: [Int64] = []        // ids to mark missing

    static func == (a: ScanDiff, b: ScanDiff) -> Bool {
        a.added == b.added && a.unchanged == b.unchanged && a.removed == b.removed
            && a.modified.map(\.id) == b.modified.map(\.id) && a.modified.map(\.entry) == b.modified.map(\.entry)
    }
}

enum IncrementalScanner {
    /// mtime comparisons are done at 1s granularity: some filesystems (FAT, SMB) truncate.
    static func sameTimestamp(_ a: Date, _ b: Date) -> Bool {
        abs(a.timeIntervalSinceReferenceDate - b.timeIntervalSinceReferenceDate) < 1.0
    }

    static func diff(existing: [String: IndexedEntry], found: [FileEntry]) -> ScanDiff {
        var diff = ScanDiff()
        var seen = Set<String>()
        seen.reserveCapacity(found.count)
        for entry in found {
            seen.insert(entry.relativePath)
            if let old = existing[entry.relativePath] {
                if old.fileSize == entry.fileSize && sameTimestamp(old.modifiedAt, entry.modifiedAt) {
                    diff.unchanged.append(old.id)
                } else {
                    diff.modified.append((old.id, entry))
                }
            } else {
                diff.added.append(entry)
            }
        }
        for (path, old) in existing where !seen.contains(path) {
            diff.removed.append(old.id)
        }
        return diff
    }
}
