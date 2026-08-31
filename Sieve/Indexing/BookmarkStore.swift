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
