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
    func copy(_ from: URL, to: URL) throws
}

extension FileSystemOps {
    /// Every file under `dir`, at any depth (not the directories themselves). Package bundles
    /// count as one file. `.DS_Store` is left out — it's Finder litter, not the user's file.
    func files(under dir: URL) throws -> [URL] {
        guard let e = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
            options: [.skipsPackageDescendants], errorHandler: { _, _ in true }) else { return [] }
        var out: [URL] = []
        for case let url as URL in e where url.lastPathComponent != ".DS_Store" {
            let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            if v?.isDirectory != true || v?.isPackage == true { out.append(url) }
        }
        return out
    }

    /// The folders directly inside `dir` (package bundles excluded).
    func subfolders(of dir: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey])
            .filter {
                let v = try? $0.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
                return v?.isDirectory == true && v?.isPackage != true
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
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
    func copy(_ from: URL, to: URL) throws { try FileManager.default.copyItem(at: from, to: to) }
}

enum FileOperation: Sendable, Equatable {
    case trash
    case deletePermanently
    case move(destination: URL)
    /// Copy into a folder; the source file and its row are left alone.
    case copy(destination: URL)

    /// The destination folder of a move or copy.
    var destination: URL? {
        switch self {
        case .move(let d), .copy(let d): d
        case .trash, .deletePermanently: nil
        }
    }

    var name: String {
        switch self {
        case .trash: "trash"
        case .deletePermanently: "delete"
        case .move: "move"
        case .copy: "copy"
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
/// duplicates view (trash / move redundant copies), the list's "Move to Folder…", and sample
/// drops onto a folder (copy or move).
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
        if let dest = op.destination {
            destScoped = dest.startAccessingSecurityScopedResource()
        }
        defer { if destScoped, let dest = op.destination { dest.stopAccessingSecurityScopedResource() } }

        // Root paths `reconcile` uses to decide whether a moved file landed inside a known root
        // (→ re-path the row) or outside every root (→ mark missing). Start with the source roots,
        // then add the root that contains a move destination even if it held no source file — so
        // moving a sample from one indexed folder into another re-paths instead of orphaning it.
        var indexedRootPaths: [(Int64, String)] = rootURLs.map { ($0.key, $0.value.standardizedFileURL.path) }
        if let dest = op.destination {
            let destPath = dest.standardizedFileURL.path
            for (id, root) in rootsById where !indexedRootPaths.contains(where: { $0.0 == id }) {
                guard root.isAvailable, let url = try? resolveRoot(root) else { continue }
                let p = url.standardizedFileURL.path
                if destPath == p || destPath.hasPrefix(p + "/") { indexedRootPaths.append((id, p)) }
            }
        }

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
                case .copy(let dest):
                    let target = Self.uniqueDestination(in: dest, filename: sample.filename, exists: fs.exists)
                    try fs.copy(url, to: target)
                    result.destination = target
                }
                result.succeeded = true
            } catch {
                result.error = error.localizedDescription
                Self.log.error("\(op.name, privacy: .public) failed for \(sample.relativePath, privacy: .public): \(error, privacy: .public)")
            }
            results.append(result)
        }

        await reconcile(op: op, results: results, samples: samples, rootPaths: indexedRootPaths)
        return results
    }

    /// Reverses a logged `move`: pulls the file back from where it was moved to and returns it to
    /// its original root + relative path, re-pathing the sample row and rescanning is left to the
    /// caller. Marks the original log row `undoneAt` and writes an "undo move" row of its own.
    /// Fails (without touching anything) if the file isn't where the log says, the original volume
    /// is offline, or the destination sits in a folder Sieve can no longer reach.
    func undoMove(_ log: FileOpLog) async -> FileOpResult {
        let home = (log.relativePath as NSString).lastPathComponent
        var result = FileOpResult(sampleId: log.sampleId ?? 0, filename: home,
                                  relativePath: log.relativePath, succeeded: false)
        guard log.isUndoableMove, let logId = log.id, let destPath = log.destinationPath else {
            result.error = "This operation can't be undone."
            return result
        }

        let roots = (try? await database.reader.read { db in try Root.fetchAll(db) }) ?? []
        let rootsById = Dictionary(uniqueKeysWithValues: roots.compactMap { r in r.id.map { ($0, r) } })
        guard let srcRoot = rootsById[log.rootId], srcRoot.isAvailable,
              let srcRootURL = try? resolveRoot(srcRoot) else {
            result.error = "The original folder isn't available — reconnect its volume and try again."
            return result
        }

        let srcScoped = srcRootURL.startAccessingSecurityScopedResource()
        defer { if srcScoped { srcRootURL.stopAccessingSecurityScopedResource() } }

        // The file now lives at `destPath`; hold scope on the indexed root that contains it (if any)
        // so the sandbox lets us move it back out.
        let destURL = URL(fileURLWithPath: destPath)
        var destRootURL: URL?
        for (_, r) in rootsById where r.isAvailable {
            guard let u = try? resolveRoot(r) else { continue }
            let p = u.standardizedFileURL.path
            if destPath == p || destPath.hasPrefix(p + "/") { destRootURL = u; break }
        }
        let destScoped = destRootURL?.startAccessingSecurityScopedResource() ?? false
        defer { if destScoped, let d = destRootURL { d.stopAccessingSecurityScopedResource() } }

        guard fs.exists(destURL) else {
            result.error = "The moved file isn't where it was left — it may have been moved or deleted "
                + "since, or it's in a folder Sieve no longer has access to."
            return result
        }

        let target = srcRootURL.appending(path: log.relativePath)
        let targetParent = target.deletingLastPathComponent()
        let finalTarget: URL
        do {
            if !fs.exists(targetParent) {
                try FileManager.default.createDirectory(at: targetParent, withIntermediateDirectories: true)
            }
            finalTarget = Self.uniqueDestination(in: targetParent, filename: target.lastPathComponent, exists: fs.exists)
            try fs.move(destURL, to: finalTarget)
        } catch {
            result.error = error.localizedDescription
            Self.log.error("undo move failed for \(destPath, privacy: .public): \(error, privacy: .public)")
            return result
        }
        result.destination = finalTarget
        result.succeeded = true

        let now = Date()
        let rel: String = {
            let rootPath = srcRootURL.standardizedFileURL.path
            var r = String(finalTarget.standardizedFileURL.path.dropFirst(rootPath.count))
            if r.hasPrefix("/") { r.removeFirst() }
            return r
        }()
        result.relativePath = rel
        let comps = rel.split(separator: "/")
        let parent = comps.dropLast().joined(separator: "/")
        let name = comps.last.map(String.init) ?? rel
        do {
            try await database.writer.write { db in
                if let sid = log.sampleId {
                    try db.execute(sql: "DELETE FROM sample WHERE rootId = ? AND relativePath = ? AND id != ?",
                                   arguments: [log.rootId, rel, sid])
                    try db.execute(sql: """
                        UPDATE sample SET rootId = ?, relativePath = ?, parentDir = ?, filename = ?,
                                          status = 'present', lastSeenAt = ? WHERE id = ?
                        """, arguments: [log.rootId, rel, parent, name, now, sid])
                }
                try db.execute(sql: "UPDATE file_op_log SET undoneAt = ? WHERE id = ?", arguments: [now, logId])
                var undo = FileOpLog(sampleId: log.sampleId, rootId: log.rootId, relativePath: rel,
                                     op: "undo move", destinationPath: destPath, performedAt: now,
                                     succeeded: true, error: nil, undoneAt: nil)
                try undo.insert(db)
            }
        } catch {
            Self.log.error("undo reconcile failed: \(error, privacy: .public)")
        }
        return result
    }

    // MARK: Flatten

    struct FlattenPlan: Sendable {
        var folderURL: URL
        var subfolders: [String]    // names of the folders directly inside
        var fileCount: Int          // files anywhere inside them (indexed or not)
    }

    struct FlattenResult: Sendable {
        var sampleResults: [FileOpResult] = []   // indexed samples (logged, undoable moves)
        var otherMoved = 0                       // un-indexed files (non-audio etc.)
        var otherFailed: [String] = []           // "path: error"
        var trashedFolders: [String] = []
        var keptFolders: [String] = []           // still had files in them — left alone
        var error: String?
        var movedCount: Int { sampleResults.filter(\.succeeded).count + otherMoved }
        var failedCount: Int { sampleResults.filter { !$0.succeeded }.count + otherFailed.count }
    }

    /// What "Flatten Folder" would do to `parentDir` ("" = the root itself), for the confirm sheet.
    func flattenPlan(rootId: Int64, parentDir: String) async -> FlattenPlan? {
        guard let rootURL = await availableRootURL(rootId) else { return nil }
        let scoped = rootURL.startAccessingSecurityScopedResource()
        defer { if scoped { rootURL.stopAccessingSecurityScopedResource() } }
        let folder = parentDir.isEmpty ? rootURL : rootURL.appending(path: parentDir)
        let subs = (try? fs.subfolders(of: folder)) ?? []
        let count = subs.reduce(0) { $0 + ((try? fs.files(under: $1).count) ?? 0) }
        return FlattenPlan(folderURL: folder, subfolders: subs.map(\.lastPathComponent), fileCount: count)
    }

    /// Moves every file from the sub-folders of `parentDir` (any depth) straight into it, then
    /// moves each emptied sub-folder to the Trash. No file is deleted: indexed samples go through
    /// `perform(.move…)` (logged in Move History, ratings/tags follow), everything else is moved
    /// as-is, and a name clash gets a " (2)" suffix. A sub-folder that still holds a file (because
    /// a move failed) is left in place.
    func flatten(rootId: Int64, parentDir: String) async -> FlattenResult {
        var result = FlattenResult()
        guard let rootURL = await availableRootURL(rootId) else {
            result.error = FileOpError.rootUnavailable.localizedDescription
            return result
        }
        let scoped = rootURL.startAccessingSecurityScopedResource()
        defer { if scoped { rootURL.stopAccessingSecurityScopedResource() } }
        let folder = parentDir.isEmpty ? rootURL : rootURL.appending(path: parentDir)

        // 1. Indexed samples below the folder.
        let below: SQL = parentDir.isEmpty ? "parentDir != ''" : "parentDir LIKE \(parentDir + "/%")"
        let samples = (try? await database.reader.read { db in
            try SQLRequest<SampleRow>(literal: """
                SELECT * FROM sample_with_annotation WHERE rootId = \(rootId) AND status = 'present' AND \(below)
                """).fetchAll(db)
        }) ?? []
        if !samples.isEmpty {
            result.sampleResults = await perform(.move(destination: folder), on: samples)
        }

        // 2. Whatever else is still in the sub-folders; 3. trash the ones left empty.
        let subs: [URL]
        do { subs = try fs.subfolders(of: folder) } catch {
            result.error = error.localizedDescription
            return result
        }
        for sub in subs {
            for file in (try? fs.files(under: sub)) ?? [] {
                let target = Self.uniqueDestination(in: folder, filename: file.lastPathComponent, exists: fs.exists)
                do {
                    try fs.move(file, to: target)
                    result.otherMoved += 1
                } catch {
                    let rel = String(file.path.dropFirst(folder.path.count + 1))
                    result.otherFailed.append("\(rel): \(error.localizedDescription)")
                }
            }
            if ((try? fs.files(under: sub)) ?? [sub]).isEmpty {
                do {
                    try fs.trash(sub)
                    result.trashedFolders.append(sub.lastPathComponent)
                } catch {
                    result.keptFolders.append(sub.lastPathComponent)
                }
            } else {
                result.keptFolders.append(sub.lastPathComponent)
            }
        }
        // A sample whose tracked move failed (e.g. changed on disk since the last scan) was still
        // moved by the plain pass above — it's counted there, not as a failure. The rescan after
        // flattening re-indexes it; its hash-keyed rating/tags re-attach.
        result.sampleResults.removeAll { !$0.succeeded && !fs.exists(rootURL.appending(path: $0.relativePath)) }
        return result
    }

    private func availableRootURL(_ rootId: Int64) async -> URL? {
        guard let root = try? await database.reader.read({ db in try Root.fetchOne(db, key: rootId) }),
              root.isAvailable else { return nil }
        return try? resolveRoot(root)
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

    private func reconcile(op: FileOperation, results: [FileOpResult], samples: [SampleRow], rootPaths: [(Int64, String)]) async {
        let byId = Dictionary(uniqueKeysWithValues: samples.map { ($0.id, $0) })
        let now = Date()
        do {
            try await database.writer.write { db in
                for r in results {
                    guard let s = byId[r.sampleId] else { continue }
                    var log = FileOpLog(sampleId: s.id, rootId: s.rootId, relativePath: s.relativePath, op: op.name,
                                        destinationPath: r.destination?.path, performedAt: now, succeeded: r.succeeded, error: r.error)
                    try log.insert(db)
                    guard r.succeeded else { continue }
                    switch op {
                    case .move:
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
                            // Moved outside every indexed root — the file is fine, just no longer ours.
                            try db.execute(sql: "UPDATE sample SET status = 'missing' WHERE id = ?", arguments: [s.id])
                        }
                    case .copy:
                        // The original stays put; the destination rescan indexes the copy, and its
                        // content hash picks up the same rating/tags/notes.
                        break
                    case .trash, .deletePermanently:
                        // The file left its folder; drop the row so it leaves the list. The
                        // hash-keyed annotation stays, so re-indexing the same audio (or a Finder
                        // "Put Back" followed by a rescan) re-attaches the rating/tags/notes.
                        try db.execute(sql: "DELETE FROM sample WHERE id = ?", arguments: [s.id])
                    }
                }
            }
        } catch {
            Self.log.error("reconcile failed: \(error, privacy: .public)")
        }
    }
}

/// Copies or moves files / folders dragged in from Finder into a folder inside an indexed root.
/// These aren't indexed samples yet, so there's nothing to re-check or reconcile — the caller
/// rescans the destination root afterwards and the scan picks them up.
enum FinderImport {
    struct Result: Identifiable, Sendable {
        let id = UUID()
        let name: String
        var destination: URL?
        var error: String?
        var succeeded: Bool { error == nil }
    }

    /// `rootURL` is the indexed root that contains `destination`; its security scope is held for
    /// the batch. Dropped URLs carry their own sandbox access from the drag.
    static func run(_ items: [URL], into destination: URL, rootURL: URL, move: Bool,
                    fs: any FileSystemOps = RealFileSystem()) -> [Result] {
        let scoped = rootURL.startAccessingSecurityScopedResource()
        defer { if scoped { rootURL.stopAccessingSecurityScopedResource() } }
        let destPath = destination.standardizedFileURL.path
        return items.map { item in
            var result = Result(name: item.lastPathComponent)
            let itemScoped = item.startAccessingSecurityScopedResource()
            defer { if itemScoped { item.stopAccessingSecurityScopedResource() } }
            let itemPath = item.standardizedFileURL.path
            do {
                guard fs.exists(item) else { throw FileOpError.missing }
                // A folder can't go inside itself.
                guard destPath != itemPath, !destPath.hasPrefix(itemPath + "/") else {
                    throw CocoaError(.fileWriteInvalidFileName)
                }
                // Already sits in the destination: moving is a no-op, copying makes a " (2)".
                if move, item.deletingLastPathComponent().standardizedFileURL.path == destPath {
                    result.destination = item
                    return result
                }
                let target = FileOperator.uniqueDestination(in: destination, filename: item.lastPathComponent,
                                                            exists: fs.exists)
                if move { try fs.move(item, to: target) } else { try fs.copy(item, to: target) }
                result.destination = target
            } catch {
                result.error = error.localizedDescription
            }
            return result
        }
    }
}
