import Foundation
import GRDB
import os

/// Filesystem side effects behind a protocol so tests can fake the Trash.
protocol FileSystemOps: Sendable {
    func exists(_ url: URL) -> Bool
    func attributes(_ url: URL) throws -> (size: Int64, modified: Date)
    func trash(_ url: URL) throws
    func remove(_ url: URL) throws
    func move(_ from: URL, to: URL) throws
}

struct RealFileSystem: FileSystemOps {
    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    func attributes(_ url: URL) throws -> (size: Int64, modified: Date) {
        let v = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return (Int64(v.fileSize ?? 0), v.contentModificationDate ?? .distantPast)
    }
    func trash(_ url: URL) throws { try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
    func remove(_ url: URL) throws { try FileManager.default.removeItem(at: url) }
    func move(_ from: URL, to: URL) throws { try FileManager.default.moveItem(at: from, to: to) }
}

enum FileOperation: Sendable, Equatable {
    case trash
    case deletePermanently
    case move(destination: URL)

    var name: String {
        switch self {
        case .trash: "trash"
        case .deletePermanently: "delete"
        case .move: "move"
        }
    }
}

struct FileOpResult: Identifiable, Sendable, Hashable {
    var id: Int64 { sampleId }
    var sampleId: Int64
    var filename: String
    var relativePath: String
    var succeeded: Bool
    var error: String?
    var destination: URL?
}

enum FileOpError: Error, LocalizedError {
    case rootUnavailable
    case changedOnDisk
    case missing
    var errorDescription: String? {
        switch self {
        case .rootUnavailable: "The folder's volume is not available."
        case .changedOnDisk: "The file changed on disk since it was indexed; rescan first."
        case .missing: "The file no longer exists."
        }
    }
}

/// Trashes / deletes / moves samples on disk, then reconciles the index. Invoked from the
/// duplicates view (trash / move redundant copies) and from the list's "Move to Folder…".
actor FileOperator {
    private let database: AppDatabase
    private let fs: any FileSystemOps
    private let resolveRoot: @Sendable (Root) throws -> URL
    private static let log = Logger(subsystem: "com.arlo.Sieve", category: "fileops")

    init(database: AppDatabase, bookmarks: BookmarkStore, fs: any FileSystemOps = RealFileSystem()) {
        self.database = database
        self.fs = fs
        self.resolveRoot = { root in try bookmarks.resolve(root.bookmarkData).url }
    }

    /// Test seam: custom root resolver (e.g. temp directories).
    init(database: AppDatabase, fs: any FileSystemOps, resolveRoot: @escaping @Sendable (Root) throws -> URL) {
        self.database = database
        self.fs = fs
        self.resolveRoot = resolveRoot
    }

    func perform(_ op: FileOperation, on samples: [SampleRow]) async -> [FileOpResult] {
        var results: [FileOpResult] = []
        let roots = (try? await database.reader.read { db in try Root.fetchAll(db) }) ?? []
        let rootsById = Dictionary(uniqueKeysWithValues: roots.compactMap { r in r.id.map { ($0, r) } })

        // Resolve every root once; hold security scope for the batch.
        var rootURLs: [Int64: URL] = [:]
        for (id, root) in rootsById where samples.contains(where: { $0.rootId == id }) {
            if root.isAvailable, let url = try? resolveRoot(root) {
                _ = url.startAccessingSecurityScopedResource()
                rootURLs[id] = url
            }
        }
        defer { for url in rootURLs.values { url.stopAccessingSecurityScopedResource() } }

        var destScoped = false
        if case .move(let dest) = op {
            destScoped = dest.startAccessingSecurityScopedResource()
        }
        defer { if destScoped, case .move(let dest) = op { dest.stopAccessingSecurityScopedResource() } }

        for sample in samples {
            var result = FileOpResult(sampleId: sample.id, filename: sample.filename, relativePath: sample.relativePath, succeeded: false)
            do {
                guard let rootURL = rootURLs[sample.rootId] else { throw FileOpError.rootUnavailable }
                let url = rootURL.appending(path: sample.relativePath)
                guard fs.exists(url) else { throw FileOpError.missing }
                let attrs = try fs.attributes(url)
                guard attrs.size == sample.fileSize, IncrementalScanner.sameTimestamp(attrs.modified, sample.modifiedAt) else {
                    throw FileOpError.changedOnDisk
                }
                switch op {
                case .trash:
                    try fs.trash(url)
                case .deletePermanently:
                    try fs.remove(url)
                case .move(let dest):
                    let target = Self.uniqueDestination(in: dest, filename: sample.filename, exists: fs.exists)
                    try fs.move(url, to: target)
                    result.destination = target
                }
                result.succeeded = true
            } catch {
                result.error = error.localizedDescription
                Self.log.error("\(op.name, privacy: .public) failed for \(sample.relativePath, privacy: .public): \(error, privacy: .public)")
            }
            results.append(result)
        }

        await reconcile(op: op, results: results, samples: samples, rootURLs: rootURLs)
        return results
    }

    /// `name.ext`, `name (2).ext`, `name (3).ext`…
    static func uniqueDestination(in dir: URL, filename: String, exists: (URL) -> Bool) -> URL {
        var candidate = dir.appending(path: filename)
        guard exists(candidate) else { return candidate }
        let stem = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var n = 2
        while true {
            let name = ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)"
            candidate = dir.appending(path: name)
            if !exists(candidate) { return candidate }
            n += 1
        }
    }

    private func reconcile(op: FileOperation, results: [FileOpResult], samples: [SampleRow], rootURLs: [Int64: URL]) async {
        let byId = Dictionary(uniqueKeysWithValues: samples.map { ($0.id, $0) })
        let now = Date()
        // Root paths for detecting moves that land inside a known root.
        let rootPaths = rootURLs.map { ($0.key, $0.value.standardizedFileURL.path) }
        do {
            try await database.writer.write { db in
                for r in results {
                    guard let s = byId[r.sampleId] else { continue }
                    var log = FileOpLog(sampleId: s.id, rootId: s.rootId, relativePath: s.relativePath, op: op.name,
                                        destinationPath: r.destination?.path, performedAt: now, succeeded: r.succeeded, error: r.error)
                    try log.insert(db)
                    guard r.succeeded else { continue }
                    if let dest = r.destination?.standardizedFileURL.path,
                       let (rootId, rootPath) = rootPaths.first(where: { dest.hasPrefix($0.1 + "/") }) {
                        var rel = String(dest.dropFirst(rootPath.count))
                        if rel.hasPrefix("/") { rel.removeFirst() }
                        let comps = rel.split(separator: "/")
                        let parent = comps.dropLast().joined(separator: "/")
                        let name = comps.last.map(String.init) ?? rel
                        // If a stale row already exists at the destination, drop it first.
                        try db.execute(sql: "DELETE FROM sample WHERE rootId = ? AND relativePath = ? AND id != ?", arguments: [rootId, rel, s.id])
                        try db.execute(sql: "UPDATE sample SET rootId = ?, relativePath = ?, parentDir = ?, filename = ?, lastSeenAt = ? WHERE id = ?",
                                       arguments: [rootId, rel, parent, name, now, s.id])
                    } else {
                        try db.execute(sql: "UPDATE sample SET status = 'missing' WHERE id = ?", arguments: [s.id])
                    }
                }
            }
        } catch {
            Self.log.error("reconcile failed: \(error, privacy: .public)")
        }
    }
}
