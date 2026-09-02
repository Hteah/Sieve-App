import AppKit
import Foundation
import UniformTypeIdentifiers

extension AppEnvironment {
    /// Opens the folder picker and registers the chosen folder as a root.
    func addRootViaPanel() async {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose folders containing samples to index."
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            do { try await scanner.addRoot(url: url) } catch { report(error) }
        }
    }

    /// Prompts for a new location for an existing root (folder moved / drive reformatted) and relinks it,
    /// preserving the root's samples, analysis, group and ordering. Kicks a rescan on success.
    func relinkRootViaPanel(rootId: Int64) async {
        guard let root = try? await database.reader.read({ db in try Root.fetchOne(db, key: rootId) }) else { return }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Relink"
        panel.message = "Choose the new location of \u{201C}\(root.name)\u{201D}."
        let oldParent = URL(fileURLWithPath: root.lastResolvedPath).deletingLastPathComponent()
        panel.directoryURL = FileManager.default.fileExists(atPath: oldParent.path)
            ? oldParent : URL(fileURLWithPath: "/Volumes", isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.urls.first else { return }

        if url.lastPathComponent != root.name {
            let alert = NSAlert()
            alert.messageText = "Relink to a differently named folder?"
            alert.informativeText = "This folder is named \u{201C}\(url.lastPathComponent)\u{201D}, "
                + "but the library folder was \u{201C}\(root.name)\u{201D}. Relink anyway?"
            alert.addButton(withTitle: "Relink")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        do {
            try await scanner.relinkRoot(id: rootId, to: url)
            rootURLCache[rootId] = nil
        } catch {
            report(error)
        }
    }

    /// Resolves a root's bookmark to a URL (cached). Caller must hold security scope on it to read children.
    func rootURL(for rootId: Int64) -> URL? {
        if let cached = rootURLCache[rootId] { return cached }
        guard let root = try? database.reader.read({ db in try Root.fetchOne(db, key: rootId) }),
              let resolved = try? bookmarks.resolve(root.bookmarkData) else { return nil }
        rootURLCache[rootId] = resolved.url
        return resolved.url
    }

    func fileURL(for row: SampleRow) -> URL? {
        rootURL(for: row.rootId)?.appending(path: row.relativePath)
    }

    /// The id of the indexed root that contains `url`, if any (used to rescan after a save).
    func rootId(containing url: URL) -> Int64? {
        let path = url.standardizedFileURL.path
        guard let roots = try? database.reader.read({ db in try Root.fetchAll(db) }) else { return nil }
        for root in roots {
            guard let id = root.id, let rootURL = rootURL(for: id) else { continue }
            let rootPath = rootURL.standardizedFileURL.path
            if path == rootPath || path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/") {
                return id
            }
        }
        return nil
    }

    func revealInFinder(_ row: SampleRow) {
        guard let root = rootURL(for: row.rootId), let url = fileURL(for: row) else { return }
        withSecurityScope(root) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    func togglePreview(_ row: SampleRow) {
        guard let root = rootURL(for: row.rootId), let url = fileURL(for: row) else { return }
        editor.player.stop()
        player.toggle(url: url, sampleId: row.id, rootURL: root)
    }

    func preview(_ row: SampleRow) {
        guard let root = rootURL(for: row.rootId), let url = fileURL(for: row) else { return }
        editor.player.stop()
        player.play(url: url, sampleId: row.id, rootURL: root)
    }

    /// Click-to-seek used by both the inspector and the list-row waveforms: if this sample is
    /// already loaded, move the playhead; otherwise start playing it from `fraction` (0...1).
    func seek(_ row: SampleRow, toFraction fraction: Double) {
        guard row.status == .present,
              let root = rootURL(for: row.rootId),
              let url = fileURL(for: row) else { return }
        let seconds = max(0, min(1, fraction)) * (row.durationSec ?? 0)
        if player.currentSampleId == row.id {
            player.seek(to: seconds)
        } else {
            player.play(url: url, sampleId: row.id, rootURL: root, from: seconds)
        }
    }

    // MARK: External audio editor

    /// Resolves the stored bookmark to the user's chosen editor app, or nil if unset/stale.
    var audioEditorURL: URL? {
        guard let data = audioEditorBookmark else { return nil }
        var stale = false
        return try? URL(resolvingBookmarkData: data, options: [.withSecurityScope],
                        relativeTo: nil, bookmarkDataIsStale: &stale)
    }

    /// Prompts for the preferred audio editor application and remembers it (security-scoped).
    @discardableResult
    func chooseAudioEditor() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Choose"
        panel.message = "Choose an application to open samples for editing."
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            let data = try url.bookmarkData(options: [.withSecurityScope],
                                            includingResourceValuesForKeys: nil, relativeTo: nil)
            audioEditorBookmark = data
            audioEditorName = url.deletingPathExtension().lastPathComponent
            UserDefaults.standard.set(data, forKey: Self.editorBookmarkKey)
            UserDefaults.standard.set(audioEditorName, forKey: Self.editorNameKey)
            return url
        } catch {
            report(error)
            return nil
        }
    }

    func clearAudioEditor() {
        audioEditorBookmark = nil
        audioEditorName = nil
        UserDefaults.standard.removeObject(forKey: Self.editorBookmarkKey)
        UserDefaults.standard.removeObject(forKey: Self.editorNameKey)
    }

    /// Opens the sample in the chosen audio editor, prompting for one the first time.
    func openInAudioEditor(_ row: SampleRow) {
        guard row.status == .present,
              let root = rootURL(for: row.rootId),
              let file = fileURL(for: row) else { return }
        guard let editor = audioEditorURL ?? chooseAudioEditor() else { return }

        let scoped = editor.startAccessingSecurityScopedResource()
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        withSecurityScope(root) {
            NSWorkspace.shared.open([file], withApplicationAt: editor, configuration: config) { [weak self] _, error in
                if scoped { editor.stopAccessingSecurityScopedResource() }
                if let error { Task { @MainActor in self?.report(error) } }
            }
        }
    }
}
