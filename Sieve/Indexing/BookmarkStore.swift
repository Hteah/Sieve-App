import Foundation
import os

/// Creates and resolves security-scoped bookmarks for user-granted folders.
final class BookmarkStore: Sendable {
    private static let log = Logger(subsystem: "com.arlo.Sieve", category: "bookmarks")

    struct Resolved: Sendable {
        var url: URL
        var isStale: Bool
        /// Fresh bookmark data if the old one was stale and could be regenerated.
        var refreshedData: Data?
    }

    func makeBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    func resolve(_ data: Data) throws -> Resolved {
        var stale = false
        let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
        var refreshed: Data?
        if stale {
            // Regenerating requires an active scope on the resolved URL.
            let ok = url.startAccessingSecurityScopedResource()
            defer { if ok { url.stopAccessingSecurityScopedResource() } }
            refreshed = try? makeBookmark(for: url)
            Self.log.info("refreshed stale bookmark for \(url.path, privacy: .public)")
        }
        return Resolved(url: url, isStale: stale, refreshedData: refreshed)
    }

    static func volumeUUID(of url: URL) -> String? {
        try? url.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
    }

    /// True when the URL's volume is mounted and the item exists.
    static func isReachable(_ url: URL) -> Bool {
        (try? url.checkResourceIsReachable()) ?? false
    }

    /// `isReachable`, but fenced by `timeout` and run off the caller's executor — `checkResourceIsReachable`
    /// can block for a minute on a stalled SMB mount, and we must not hang the scan actor on it.
    /// A timeout counts as not reachable; the blocking probe is abandoned (it unwinds when the mount does).
    static func isReachable(_ url: URL, timeout: Duration) async -> Bool {
        await firstResult(within: timeout) { withSecurityScope(url) { isReachable(url) } } ?? false
    }

    // Remembered destination folder for "Move to…" (bookmark stored in UserDefaults).
    private static let moveDestinationKey = "moveDestinationBookmark"

    func rememberMoveDestination(_ url: URL) {
        if let data = try? makeBookmark(for: url) {
            UserDefaults.standard.set(data, forKey: Self.moveDestinationKey)
        }
    }

    func lastMoveDestination() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: Self.moveDestinationKey),
              let r = try? resolve(data) else { return nil }
        return r.url
    }

    // Remembered folder for the editor's "Save As New…" (bookmark stored in UserDefaults).
    private static let saveDestinationKey = "saveDestinationBookmark"

    func rememberSaveDestination(_ url: URL) {
        if let data = try? makeBookmark(for: url) {
            UserDefaults.standard.set(data, forKey: Self.saveDestinationKey)
        }
    }

    func lastSaveDestination() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: Self.saveDestinationKey),
              let r = try? resolve(data) else { return nil }
        return r.url
    }

    // Folder the editor writes recordings into (bookmark stored in UserDefaults).
    private static let recordingsFolderKey = "recordingsFolderBookmark"

    func rememberRecordingsFolder(_ url: URL) {
        if let data = try? makeBookmark(for: url) {
            UserDefaults.standard.set(data, forKey: Self.recordingsFolderKey)
        }
    }

    func lastRecordingsFolder() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: Self.recordingsFolderKey),
              let r = try? resolve(data) else { return nil }
        return r.url
    }

    func clearRecordingsFolder() {
        UserDefaults.standard.removeObject(forKey: Self.recordingsFolderKey)
    }

    // Remembered folder for the editor's "Export Selection" (bookmark stored in UserDefaults).
    private static let exportFolderKey = "exportFolderBookmark"

    func rememberExportFolder(_ url: URL) {
        if let data = try? makeBookmark(for: url) {
            UserDefaults.standard.set(data, forKey: Self.exportFolderKey)
        }
    }

    func lastExportFolder() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: Self.exportFolderKey),
              let r = try? resolve(data) else { return nil }
        return r.url
    }

    func clearExportFolder() {
        UserDefaults.standard.removeObject(forKey: Self.exportFolderKey)
    }
}

/// Runs `body` while holding security-scoped access to `url`. Balanced start/stop.
func withSecurityScope<T>(_ url: URL, _ body: () throws -> T) rethrows -> T {
    let ok = url.startAccessingSecurityScopedResource()
    defer { if ok { url.stopAccessingSecurityScopedResource() } }
    return try body()
}

func withSecurityScope<T>(_ url: URL, _ body: () async throws -> T) async rethrows -> T {
    let ok = url.startAccessingSecurityScopedResource()
    defer { if ok { url.stopAccessingSecurityScopedResource() } }
    return try await body()
}

/// Runs `operation` on a detached task and returns its result, or `nil` if `timeout` elapses first.
/// After a timeout the operation is left running (a task group would force us to await it) — use this
/// to fence a synchronous call that can otherwise block indefinitely, e.g. a hung network mount, at
/// the cost of parking one pool thread until that call finally returns.
func firstResult<T: Sendable>(within timeout: Duration,
                              of operation: @escaping @Sendable () -> T) async -> T? {
    let gate = FirstResultGate()
    return await withCheckedContinuation { (cont: CheckedContinuation<T?, Never>) in
        Task.detached {
            let value = operation()
            gate.settle { cont.resume(returning: value) }
        }
        Task {
            try? await Task.sleep(for: timeout)
            gate.settle { cont.resume(returning: nil) }
        }
    }
}

/// Lets exactly one of two racing tasks resume a continuation.
private final class FirstResultGate: @unchecked Sendable {
    private let lock = NSLock()
    private var settled = false
    func settle(_ resume: () -> Void) {
        lock.lock()
        let firstToArrive = !settled
        settled = true
        lock.unlock()
        if firstToArrive { resume() }
    }
}
