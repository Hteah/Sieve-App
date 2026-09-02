import Foundation
import GRDB
import os

enum ScanPhase: Sendable, Equatable {
    case checking, enumerating, diffing, enriching, finished
    var label: String {
        switch self {
        case .checking: "Checking"
        case .enumerating: "Listing files"
        case .diffing: "Comparing"
        case .enriching: "Analyzing"
        case .finished: "Done"
        }
    }
}

struct ScanProgress: Sendable {
    var rootId: Int64
    var rootName: String
    var phase: ScanPhase
    var done: Int
    var total: Int
}

enum ScanError: Error, LocalizedError {
    case rootNotFound
    case unavailable(String)
    var errorDescription: String? {
        switch self {
        case .rootNotFound: "Folder not found in library."
        case .unavailable(let p): "\(p) is not reachable right now."
        }
    }
}

/// Runs scans for roots, one task per root, and publishes progress.
actor ScanCoordinator {
    private let database: AppDatabase
    private let bookmarks: BookmarkStore
    private var tasks: [Int64: Task<Void, Never>] = [:]
    private var listeners: [UUID: AsyncStream<ScanProgress>.Continuation] = [:]
    private static let log = Logger(subsystem: "com.arlo.Sieve", category: "scan")

    var extensions: Set<String> = Set(Queries.audioExtensions)

    init(database: AppDatabase, bookmarks: BookmarkStore) {
        self.database = database
        self.bookmarks = bookmarks
    }

    // MARK: Progress

    func progressStream() -> AsyncStream<ScanProgress> {
        let id = UUID()
        return AsyncStream { continuation in
            listeners[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeListener(id) }
            }
        }
    }

    private func removeListener(_ id: UUID) { listeners[id] = nil }

    private func publish(_ p: ScanProgress) {
        for c in listeners.values { c.yield(p) }
    }

    // MARK: Roots

    /// Registers a user-selected folder and starts an initial scan.
    @discardableResult
    func addRoot(url: URL) async throws -> Root {
        let data = try withSecurityScope(url) { try bookmarks.makeBookmark(for: url) }
        let draft = Root(name: url.lastPathComponent, bookmarkData: data,
                         lastResolvedPath: url.path, volumeUUID: BookmarkStore.volumeUUID(of: url))
        let root = try await database.writer.write { db in
            var r = draft
            try r.insert(db)
            return r
        }
        if let id = root.id { scan(rootId: id) }
        return root
    }

    func removeRoot(id: Int64) async throws {
        cancel(rootId: id)
        _ = try await database.writer.write { db in
            try Root.deleteOne(db, key: id)
        }
    }

    /// Points an existing root at a new location (folder moved, drive reformatted) without losing the
    /// row — so its samples, analysis, group membership and ordering survive. Mints a fresh bookmark for
    /// `newURL` and kicks a scan; the scan reconciles `isAvailable` and per-file status.
    func relinkRoot(id: Int64, to newURL: URL) async throws {
        cancel(rootId: id)
        let data = try withSecurityScope(newURL) { try bookmarks.makeBookmark(for: newURL) }
        try await applyRelink(id: id, newURL: newURL, bookmarkData: data,
                              volumeUUID: BookmarkStore.volumeUUID(of: newURL))
        scan(rootId: id)
    }

    /// The DB half of a relink: swap the bookmark/path/volume, keep every identity and stats field.
    /// Availability and per-sample status are left for the follow-up scan to set.
    func applyRelink(id: Int64, newURL: URL, bookmarkData: Data, volumeUUID: String?) async throws {
        try await database.writer.write { db in
            guard var root = try Root.fetchOne(db, key: id) else { throw ScanError.rootNotFound }
            root.bookmarkData = bookmarkData
            root.lastResolvedPath = newURL.path
            root.volumeUUID = volumeUUID
            try root.update(db)
        }
    }

    func scanAll() async {
        let ids = (try? await database.reader.read { db in try Int64.fetchAll(db, sql: "SELECT id FROM root") }) ?? []
        for id in ids { scan(rootId: id) }
    }

    func cancel(rootId: Int64) {
        tasks[rootId]?.cancel()
    }

    func cancelAll() {
        for t in tasks.values { t.cancel() }
    }

    var isScanning: Bool { !tasks.isEmpty }

    func scan(rootId: Int64) {
        guard tasks[rootId] == nil else { return }
        tasks[rootId] = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.runScan(rootId: rootId)
            } catch is CancellationError {
                Self.log.info("scan cancelled for root \(rootId)")
            } catch {
                Self.log.error("scan failed for root \(rootId): \(error, privacy: .public)")
            }
            await self.finish(rootId: rootId)
        }
    }

    private func finish(rootId: Int64) {
        tasks[rootId] = nil
        let name = (try? database.reader.read { db in try String.fetchOne(db, sql: "SELECT name FROM root WHERE id = ?", arguments: [rootId]) }) ?? ""
        publish(ScanProgress(rootId: rootId, rootName: name ?? "", phase: .finished, done: 0, total: 0))
    }

    /// Re-checks reachability of every root without a full scan; kicks a scan for roots that came back.
    func refreshAvailability() async {
        guard let roots = try? await database.reader.read({ db in try Root.fetchAll(db) }) else { return }
        for root in roots {
            guard let id = root.id else { continue }
            let reachable = (try? bookmarks.resolve(root.bookmarkData)).map { r in
                withSecurityScope(r.url) { BookmarkStore.isReachable(r.url) }
            } ?? false
            if reachable != root.isAvailable {
                if reachable {
                    scan(rootId: id)
                } else {
                    try? await markUnavailable(rootId: id)
                }
            }
        }
    }

    func purgeMissing() async {
        _ = try? await database.writer.write { db in
            try db.execute(sql: "DELETE FROM sample WHERE status = 'missing'")
        }
    }

    // MARK: Scan pipeline

    private func markUnavailable(rootId: Int64) async throws {
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE root SET isAvailable = 0 WHERE id = ?", arguments: [rootId])
            try db.execute(sql: "UPDATE sample SET status = 'unavailable' WHERE rootId = ? AND status != 'missing'", arguments: [rootId])
        }
    }

    private func runScan(rootId: Int64) async throws {
        guard let root = try await database.reader.read({ db in try Root.fetchOne(db, key: rootId) }) else {
            throw ScanError.rootNotFound
        }
        let name = root.name
        publish(ScanProgress(rootId: rootId, rootName: name, phase: .checking, done: 0, total: 0))

        // 1. Resolve bookmark, check reachability.
        let resolved: BookmarkStore.Resolved
        do {
            resolved = try bookmarks.resolve(root.bookmarkData)
        } catch {
            try await markUnavailable(rootId: rootId)
            throw ScanError.unavailable(root.lastResolvedPath)
        }
        if let fresh = resolved.refreshedData {
            try await database.writer.write { db in
                try db.execute(sql: "UPDATE root SET bookmarkData = ?, lastResolvedPath = ? WHERE id = ?",
                               arguments: [fresh, resolved.url.path, rootId])
            }
        }
        let url = resolved.url
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        guard BookmarkStore.isReachable(url) else {
            try await markUnavailable(rootId: rootId)
            throw ScanError.unavailable(url.path)
        }

        try await database.writer.write { db in
            try db.execute(sql: "UPDATE root SET isAvailable = 1, lastScanStarted = ?, lastResolvedPath = ? WHERE id = ?",
                           arguments: [Date(), url.path, rootId])
        }

        // 2. Enumerate.
        publish(ScanProgress(rootId: rootId, rootName: name, phase: .enumerating, done: 0, total: 0))
        let exts = extensions
        let found = try FileEnumerator.audioFiles(under: url, extensions: exts, isCancelled: { Task.isCancelled })
        try Task.checkCancellation()

        // 3. Diff.
        publish(ScanProgress(rootId: rootId, rootName: name, phase: .diffing, done: 0, total: found.count))
        let existing: [String: IndexedEntry] = try await database.reader.read { db in
            var map: [String: IndexedEntry] = [:]
            let rows = try Row.fetchCursor(db, sql: "SELECT id, relativePath, fileSize, modifiedAt, status FROM sample WHERE rootId = ?", arguments: [rootId])
            while let row = try rows.next() {
                map[row["relativePath"]] = IndexedEntry(id: row["id"], fileSize: row["fileSize"], modifiedAt: row["modifiedAt"], status: row["status"])
            }
            return map
        }
        let diff = IncrementalScanner.diff(existing: existing, found: found)
        Self.log.info("root \(name, privacy: .public): +\(diff.added.count) ~\(diff.modified.count) =\(diff.unchanged.count) -\(diff.removed.count)")

        // 4. Apply diff in batches.
        let now = Date()
        try await database.writer.write { db in
            for chunk in diff.added.chunks(ofCount: 500) {
                for entry in chunk {
                    var s = Sample(rootId: rootId, relativePath: entry.relativePath, fileSize: entry.fileSize, modifiedAt: entry.modifiedAt, now: now)
                    try s.insert(db)
                }
            }
            for (id, entry) in diff.modified {
                try db.execute(sql: """
                    UPDATE sample SET fileSize = ?, modifiedAt = ?, status = 'present', lastSeenAt = ?,
                        fileHash = NULL, audioHash = NULL, waveform = NULL, indexedAt = NULL
                    WHERE id = ?
                    """, arguments: [entry.fileSize, entry.modifiedAt, now, id])
            }
            for chunk in diff.unchanged.chunks(ofCount: 900) {
                let ids = Array(chunk)
                try db.execute(sql: "UPDATE sample SET status = 'present', lastSeenAt = ? WHERE id IN (\(databaseQuestionMarks(count: ids.count)))",
                               arguments: StatementArguments([now] + ids.map { $0 as (any DatabaseValueConvertible)? }))
            }
            for chunk in diff.removed.chunks(ofCount: 900) {
                let ids = Array(chunk)
                try db.execute(sql: "UPDATE sample SET status = 'missing' WHERE id IN (\(databaseQuestionMarks(count: ids.count)))",
                               arguments: StatementArguments(ids))
            }
            try db.execute(sql: "UPDATE root SET fileCount = ? WHERE id = ?", arguments: [found.count, rootId])
        }
        try Task.checkCancellation()

        // 5. Enrich anything not yet analyzed (added + modified, or leftovers from a cancelled run).
        try await enrich(rootId: rootId, rootName: name, rootURL: url)

        try await database.writer.write { db in
            try db.execute(sql: "UPDATE root SET lastScanCompleted = ? WHERE id = ?", arguments: [Date(), rootId])
        }
    }

    private struct Pending: Sendable {
        var id: Int64
        var relativePath: String
    }

    private func enrich(rootId: Int64, rootName: String, rootURL: URL) async throws {
        let pending: [Pending] = try await database.reader.read { db in
            try Row.fetchAll(db, sql: "SELECT id, relativePath FROM sample WHERE rootId = ? AND status = 'present' AND indexedAt IS NULL", arguments: [rootId])
                .map { Pending(id: $0["id"], relativePath: $0["relativePath"]) }
        }
        let total = pending.count
        guard total > 0 else { return }
        var done = 0
        publish(ScanProgress(rootId: rootId, rootName: rootName, phase: .enriching, done: 0, total: total))

        let width = max(2, ProcessInfo.processInfo.activeProcessorCount - 1)
        var buffer: [(Int64, AudioAnalysis)] = []

        try await withThrowingTaskGroup(of: (Int64, AudioAnalysis).self) { group in
            var iterator = pending.makeIterator()
            func addNext() -> Bool {
                guard let p = iterator.next() else { return false }
                let url = rootURL.appending(path: p.relativePath)
                group.addTask {
                    try Task.checkCancellation()
                    return (p.id, AudioAnalyzer.analyze(url: url))
                }
                return true
            }
            for _ in 0..<width { if !addNext() { break } }

            while let (id, analysis) = try await group.next() {
                buffer.append((id, analysis))
                done += 1
                if buffer.count >= 200 || done == total {
                    let batch = buffer
                    buffer.removeAll(keepingCapacity: true)
                    try await writeAnalyses(batch)
                    publish(ScanProgress(rootId: rootId, rootName: rootName, phase: .enriching, done: done, total: total))
                }
                _ = addNext()
            }
        }
        if !buffer.isEmpty { try await writeAnalyses(buffer) }
    }

    private func writeAnalyses(_ batch: [(Int64, AudioAnalysis)]) async throws {
        let now = Date()
        try await database.writer.write { db in
            for (id, a) in batch {
                try db.execute(sql: """
                    UPDATE sample SET fileHash = ?, audioHash = ?, durationSec = ?, sampleRate = ?, channels = ?,
                        bitDepth = ?, formatName = ?, bpm = COALESCE(bpm, ?), musicalKey = COALESCE(musicalKey, ?),
                        waveform = ?, peakDb = ?, rmsDb = ?, clippedSamples = ?, indexedAt = ?
                    WHERE id = ?
                    """, arguments: [a.fileHash, a.audioHash, a.metadata?.durationSec, a.metadata?.sampleRate, a.metadata?.channels,
                                     a.metadata?.bitDepth, a.metadata?.formatName, a.hints.bpm, a.hints.key,
                                     a.waveform?.encoded(), a.peakDb, a.rmsDb, a.clippedSamples, now, id])
            }
        }
    }
}

extension Array {
    func chunks(ofCount n: Int) -> [ArraySlice<Element>] {
        guard n > 0, !isEmpty else { return isEmpty ? [] : [self[...]] }
        return stride(from: 0, to: count, by: n).map { self[$0..<Swift.min($0 + n, count)] }
    }
}
