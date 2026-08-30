import Foundation
import SwiftUI
import os

/// Composition root: everything long-lived hangs off this and is injected via SwiftUI environment.
@MainActor
@Observable
final class AppEnvironment {
    let database: AppDatabase
    let bookmarks: BookmarkStore
    let scanner: ScanCoordinator
    let player: PreviewPlayer
    let volumeMonitor: VolumeMonitor
    var scanState = ScanState()
    var lastError: String?
    /// Display name of the user's chosen external audio editor, or nil if none is set.
    var audioEditorName: String?
    @ObservationIgnored var rootURLCache: [Int64: URL] = [:]
    @ObservationIgnored var audioEditorBookmark: Data?

    static let editorBookmarkKey = "audioEditorBookmark"
    static let editorNameKey = "audioEditorName"

    static let log = Logger(subsystem: "com.arlo.Sieve", category: "app")

    init(database: AppDatabase) {
        self.database = database
        self.bookmarks = BookmarkStore()
        self.scanner = ScanCoordinator(database: database, bookmarks: bookmarks)
        self.player = PreviewPlayer()
        self.volumeMonitor = VolumeMonitor()
        self.audioEditorBookmark = UserDefaults.standard.data(forKey: Self.editorBookmarkKey)
        self.audioEditorName = UserDefaults.standard.string(forKey: Self.editorNameKey)
        Task { await observeScanProgress() }
        volumeMonitor.onChange = { [weak self] in
            Task { await self?.scanner.refreshAvailability() }
        }
        #if DEBUG
        // Debug hook: SIEVE_ADD_ROOT=/path adds a root at launch (path must be sandbox-accessible).
        if let path = ProcessInfo.processInfo.environment["SIEVE_ADD_ROOT"] {
            Task {
                do { try await scanner.addRoot(url: URL(fileURLWithPath: path, isDirectory: true)) }
                catch { report(error) }
            }
        }
        #endif
    }

    static func live() -> AppEnvironment {
        do {
            return AppEnvironment(database: try AppDatabase.onDisk())
        } catch {
            log.error("failed to open database: \(error, privacy: .public)")
            // Fall back to in-memory so the app still launches.
            return AppEnvironment(database: try! AppDatabase.inMemory())
        }
    }

    private func observeScanProgress() async {
        for await progress in await scanner.progressStream() {
            scanState.apply(progress)
        }
    }

    func report(_ error: any Error) {
        lastError = String(describing: error)
        Self.log.error("\(error, privacy: .public)")
    }
}

/// Aggregated scan progress for the UI.
struct ScanState: Sendable {
    var activeRoots: [Int64: ScanProgress] = [:]
    var isScanning: Bool { !activeRoots.isEmpty }
    var summary: String {
        let list = activeRoots.values.sorted { $0.rootName < $1.rootName }
        guard !list.isEmpty else { return "" }
        return list.map { "\($0.rootName): \($0.phase.label) \($0.done)/\($0.total)" }.joined(separator: " · ")
    }
    var fraction: Double? {
        let total = activeRoots.values.reduce(0) { $0 + $1.total }
        let done = activeRoots.values.reduce(0) { $0 + $1.done }
        guard total > 0 else { return nil }
        return Double(done) / Double(total)
    }
    mutating func apply(_ p: ScanProgress) {
        if p.phase == .finished { activeRoots[p.rootId] = nil } else { activeRoots[p.rootId] = p }
    }
}
