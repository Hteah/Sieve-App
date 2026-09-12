import Foundation

/// A file found on disk during enumeration.
struct FileEntry: Hashable, Sendable {
    var relativePath: String
    var fileSize: Int64
    var modifiedAt: Date
    var createdAt: Date
}

enum FileEnumerationError: Error {
    case aborted(underlying: any Error)
}

enum FileEnumerator {
    /// Recursively lists audio files under `root`. Throws if the enumeration itself fails
    /// (e.g. the volume disappeared) so the caller can abort without marking files missing.
    static func audioFiles(under root: URL, extensions: Set<String>, isCancelled: () -> Bool = { false }) throws -> [FileEntry] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey, .isPackageKey]
        nonisolated(unsafe) var enumerationError: (any Error)?
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw FileEnumerationError.aborted(underlying: CocoaError(.fileReadUnknown))
        }

        let rootPath = root.standardizedFileURL.path
        var result: [FileEntry] = []
        for case let url as URL in enumerator {
            if isCancelled() { throw CancellationError() }
            let ext = url.pathExtension.lowercased()
            guard extensions.contains(ext) else { continue }
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { continue }
            let full = url.standardizedFileURL.path
            guard full.hasPrefix(rootPath) else { continue }
            var rel = String(full.dropFirst(rootPath.count))
            if rel.hasPrefix("/") { rel.removeFirst() }
            let modifiedAt = values.contentModificationDate ?? .distantPast
            result.append(FileEntry(
                relativePath: rel,
                fileSize: Int64(values.fileSize ?? 0),
                modifiedAt: modifiedAt,
                // Some filesystems (FAT, SMB) don't report a creation date; fall back to mtime
                // rather than surface a nonsensical `.distantPast`.
                createdAt: values.creationDate ?? modifiedAt
            ))
        }
        if let enumerationError {
            throw FileEnumerationError.aborted(underlying: enumerationError)
        }
        return result
    }
}
