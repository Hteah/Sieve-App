import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers
import os

/// The single audio-editing session behind the inspector's Edit tab and the pop-out editor
/// window. Both viewports render the same session, so they share one clip, selection, undo
/// stack and clipboard. Lives on `AppEnvironment`.
@MainActor
@Observable
final class EditorSession {
    struct Source: Sendable {
        var sampleId: Int64
        var url: URL
        var rootURL: URL
        var rootId: Int64
        var oldHash: String?
        var sourceBits: BitDepthOption
    }

    private unowned let env: AppEnvironment
    let player = AudioEditorPlayer()
    let recorder: AudioRecorder

    private(set) var source: Source?
    private(set) var clip: AudioClip?
    private(set) var mip: PeakMip?
    private(set) var thumbnail: WaveformSummary?
    var selection: Range<Int>?
    var looping = false {
        didSet { if oldValue != looping, player.isPlaying { startPlayback() } }
    }
    private(set) var isBusy = false
    private(set) var loadError: String?
    private(set) var clipboard: AudioClip?
    private(set) var lastExportURL: URL?
    /// True while the pop-out editor window is open; the inspector's Edit tab hides its editor then.
    var windowOpen = false

    private var undo: [AudioClip] = []
    private var redo: [AudioClip] = []
    private var undoBytes = 0
    private let undoBudget = 256 * 1024 * 1024
    private var editSerial = 0
    private var savedSerial = 0
    private var activeCount = 0

    static let log = Logger(subsystem: "com.arlo.Sieve", category: "editor")

    init(env: AppEnvironment) {
        self.env = env
        self.recorder = AudioRecorder(env: env, player: player)
    }

    /// Starts/stops capturing input to a new WAV. Editor playback is left alone so you can play
    /// the loaded file while a take runs; only the list-preview player is silenced.
    func toggleRecording() {
        if recorder.isRecording {
            recorder.stop()
        } else {
            env.player.stop()
            Task { await recorder.start() }
        }
    }

    private enum LoadOutcome: Sendable { case loaded(AudioClip); case failure(String) }
    private enum WriteOutcome: Sendable { case url(URL); case ok; case failure(String) }

    private nonisolated static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    // MARK: Derived

    var hasClip: Bool { clip != nil }
    var isActive: Bool { activeCount > 0 }
    var isDirty: Bool { editSerial != savedSerial }
    var canUndo: Bool { !undo.isEmpty }
    var canRedo: Bool { !redo.isEmpty }
    var hasClipboard: Bool { clipboard != nil }
    var frameCount: Int { clip?.frameCount ?? 0 }
    var channelCount: Int { clip?.channelCount ?? 0 }
    var sampleRate: Double { clip?.sampleRate ?? 44_100 }
    var duration: Double { clip?.duration ?? 0 }

    var hasSelection: Bool {
        if let s = selection { return !s.isEmpty }
        return false
    }

    /// The range an op acts on: the selection, or the whole clip when there is none.
    var effectiveRange: Range<Int> {
        guard let clip else { return 0..<0 }
        if let s = selection, !s.isEmpty { return clip.clampedRange(s) }
        return 0..<clip.frameCount
    }

    /// Editable frame ceiling — roughly the Settings "max minutes" at 96 kHz.
    static var maxFrames: Int {
        let minutes = UserDefaults.standard.object(forKey: "editorMaxMinutes") as? Int ?? 10
        return max(1, minutes) * 60 * 96_000
    }

    // MARK: Lifecycle / viewport refcount

    func retain(currentRow: SampleRow?) {
        activeCount += 1
        guard activeCount == 1, let row = currentRow else { return }
        if source?.sampleId != row.id || clip == nil {
            Task { await open(row: row) }
        }
    }

    func release() {
        activeCount = max(0, activeCount - 1)
        if activeCount == 0 { player.stop() }
    }

    /// Loads `row` for editing. Caller must have resolved any unsaved-edits prompt first.
    func open(row: SampleRow) async {
        player.stop()
        undo.removeAll(); redo.removeAll(); undoBytes = 0
        editSerial += 1; savedSerial = editSerial
        selection = nil
        cursor = 0
        loadError = nil
        clip = nil; mip = nil; thumbnail = nil   // show the loading state, not the previous file

        guard row.status == .present,
              let rootURL = env.rootURL(for: row.rootId),
              let fileURL = env.fileURL(for: row) else {
            clip = nil; mip = nil; source = nil
            loadError = "The file is missing or on an unavailable volume."
            return
        }

        let src = Source(sampleId: row.id, url: fileURL, rootURL: rootURL, rootId: row.rootId,
                         oldHash: row.contentHash, sourceBits: Self.bits(for: row))
        source = src
        isBusy = true
        let outcome = await Self.loadClip(url: fileURL, rootURL: rootURL, maxFrames: Self.maxFrames)
        isBusy = false
        guard source?.sampleId == src.sampleId else { return }   // selection moved on while we loaded
        switch outcome {
        case .loaded(let c):
            clip = c
            rebuildDerived(for: c)          // zoom pyramid + list thumbnail follow, off-main
        case .failure(let message):
            clip = nil; mip = nil; thumbnail = nil
            loadError = message
        }
    }

    /// Decodes the file to a clip off the main actor while holding the root's security scope.
    /// `rootURL` scope is process-wide, so acquiring it here and releasing after the detached
    /// read is safe. The zoom pyramid is built separately so the waveform can appear first.
    private static func loadClip(url: URL, rootURL: URL, maxFrames: Int) async -> LoadOutcome {
        let scoped = rootURL.startAccessingSecurityScopedResource()
        defer { if scoped { rootURL.stopAccessingSecurityScopedResource() } }
        return await Task.detached(priority: .userInitiated) {
            do { return .loaded(try AudioFileIO.load(url: url, maxFrames: maxFrames)) }
            catch { return .failure(describe(error)) }
        }.value
    }

    /// Drops the clip and any edits (used when switching away after the user chose "Discard").
    func discard() {
        player.stop()
        clip = nil; mip = nil; thumbnail = nil; source = nil; selection = nil
        cursor = 0
        undo.removeAll(); redo.removeAll(); undoBytes = 0
        editSerial = 0; savedSerial = 0
        loadError = nil
    }

    // MARK: Mirror to the list

    /// Live thumbnail for `sampleId` while it's the dirty file open in the editor — so the list
    /// row's waveform reflects unsaved edits without a rescan.
    func liveThumbnail(for sampleId: Int64) -> WaveformSummary? {
        guard isDirty, source?.sampleId == sampleId else { return nil }
        return thumbnail
    }

    /// The sample the editor is currently playing, if any (for the list row's playing indicator).
    var playingSampleId: Int64? {
        (player.isPlaying && source != nil) ? source?.sampleId : nil
    }

    var playheadFraction: Double? {
        guard player.isPlaying, frameCount > 0 else { return nil }
        return Double(player.playheadFrame) / Double(frameCount)
    }

    func revert() async {
        guard let src = source else { return }
        undo.removeAll(); redo.removeAll(); undoBytes = 0
        editSerial += 1; savedSerial = editSerial
        selection = nil
        cursor = 0
        clip = nil; mip = nil; thumbnail = nil
        isBusy = true
        let outcome = await Self.loadClip(url: src.url, rootURL: src.rootURL, maxFrames: Self.maxFrames)
        isBusy = false
        switch outcome {
        case .loaded(let c): clip = c; loadError = nil; rebuildDerived(for: c)
        case .failure(let message): loadError = message
        }
    }

    // MARK: Edits

    func trimToSelection() {
        guard let c = clip, hasSelection else { return }
        mutate(c.cropped(to: effectiveRange)) { _ in nil }
    }

    func deleteSelection() {
        guard let c = clip, hasSelection else { return }
        mutate(c.removingRange(effectiveRange)) { r in r.lowerBound..<r.lowerBound }
    }

    func normalize(toDb db: Float) {
        guard let c = clip else { return }
        mutate(c.normalizedToPeak(db: db, in: effectiveRange)) { $0 }
    }

    func amplify(db: Float) {
        guard let c = clip else { return }
        mutate(c.amplified(db: db, in: effectiveRange)) { $0 }
    }

    func reverse() {
        guard let c = clip else { return }
        mutate(c.reversed(in: effectiveRange)) { $0 }
    }

    func fadeIn() {
        guard let c = clip else { return }
        mutate(c.fadedIn(in: effectiveRange)) { $0 }
    }

    func fadeOut() {
        guard let c = clip else { return }
        mutate(c.fadedOut(in: effectiveRange)) { $0 }
    }

    func silence() {
        guard let c = clip else { return }
        mutate(c.silenced(in: effectiveRange)) { $0 }
    }

    func copySelection() {
        guard let c = clip, hasSelection else { return }
        clipboard = c.cropped(to: effectiveRange)
    }

    func cut() {
        guard let c = clip, hasSelection else { return }
        clipboard = c.cropped(to: effectiveRange)
        mutate(c.removingRange(effectiveRange)) { r in r.lowerBound..<r.lowerBound }
    }

    func paste() {
        guard let c = clip, let cb = clipboard else { return }
        let insertLen = cb.conformed(toRate: c.sampleRate, channelCount: max(1, c.channelCount)).frameCount
        mutate(c.replacingRange(effectiveRange, with: cb)) { r in r.lowerBound..<(r.lowerBound + insertLen) }
    }

    func undoEdit() {
        guard let prev = undo.popLast(), let cur = clip else { return }
        redo.append(cur)
        undoBytes -= Self.bytes(prev)
        editSerial += 1
        clip = prev
        selection = selection.flatMap { Self.clamp($0, count: prev.frameCount) }
        cursor = min(cursor, prev.frameCount)
        rebuildDerived(for: prev)
    }

    func redoEdit() {
        guard let next = redo.popLast(), let cur = clip else { return }
        undo.append(cur); undoBytes += Self.bytes(cur)
        editSerial += 1
        clip = next
        selection = selection.flatMap { Self.clamp($0, count: next.frameCount) }
        cursor = min(cursor, next.frameCount)
        rebuildDerived(for: next)
    }

    func selectAll() {
        guard frameCount > 0 else { return }
        selection = 0..<frameCount
    }

    func clearSelection() { selection = nil }

    // MARK: Playback

    /// Insertion point where playback starts when nothing is selected. Set by clicking the
    /// waveform; shown as a line when not playing.
    var cursor = 0

    /// What Play / Loop act on: the selection if there is one, otherwise from the cursor to the end.
    private var playbackRange: Range<Int> {
        guard let clip, clip.frameCount > 0 else { return 0..<0 }
        if let s = selection, !s.isEmpty { return clip.clampedRange(s) }
        let start = max(0, min(cursor, clip.frameCount - 1))
        return start..<clip.frameCount
    }

    func togglePlay() {
        if player.isPlaying { stopPlayback() } else { startPlayback() }
    }

    func startPlayback() {
        guard let clip, playbackRange.count > 0 else { return }
        env.player.stop()
        player.play(clip, range: playbackRange, looping: looping)
    }

    /// Stops playback, leaving the cursor where the playhead was so Play resumes from there.
    func stopPlayback() {
        if player.isPlaying { cursor = max(0, min(frameCount, player.playheadFrame)) }
        player.stop()
    }

    /// Moves the insertion point (from a waveform click); jumps live playback there too.
    func setCursor(_ frame: Int) {
        cursor = max(0, min(frameCount, frame))
        if player.isPlaying { startPlayback() }
    }

    // MARK: Save

    func saveReplacingOriginal(bits: BitDepthOption) async {
        guard let clip, let src = source, clip.frameCount > 0 else { return }
        isBusy = true
        defer { isBusy = false }
        player.stop()

        let outcome = await Self.replaceOnDisk(clip: clip, originalURL: src.url, rootURL: src.rootURL,
                                               bits: Self.resolve(bits))
        switch outcome {
        case .url(let written):
            let newHash = withSecurityScope(src.rootURL) { AudioAnalyzer.analyze(url: written).audioHash }
            if let old = src.oldHash, let newHash, old != newHash {
                let rel = relativePath(of: written, under: src.rootURL) ?? written.lastPathComponent
                try? await AnnotationStore(database: env.database)
                    .carryOverAnnotation(from: old, to: newHash, rootId: src.rootId, relativePath: rel)
            }
            source = Source(sampleId: src.sampleId, url: written, rootURL: src.rootURL, rootId: src.rootId,
                            oldHash: newHash ?? src.oldHash, sourceBits: bits)
            savedSerial = editSerial
            await env.scanner.scan(rootId: src.rootId)
        case .failure(let message):
            loadError = message
        case .ok:
            break
        }
    }

    func saveAsNewFile(bits: BitDepthOption) async {
        guard let clip, let src = source, clip.frameCount > 0 else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.wav]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = src.url.deletingPathExtension().lastPathComponent + " edit.wav"
        if let dir = env.bookmarks.lastSaveDestination() { panel.directoryURL = dir }
        panel.message = "Save the edited audio as a new WAV file."
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        env.bookmarks.rememberSaveDestination(dest.deletingLastPathComponent())

        isBusy = true
        defer { isBusy = false }
        let outcome = await Self.writeFile(clip: clip, to: dest, bits: Self.resolve(bits))
        switch outcome {
        case .ok:
            if let rootId = env.rootId(containing: dest) { await env.scanner.scan(rootId: rootId) }
        case .failure(let message):
            loadError = message
        case .url:
            break
        }
    }

    /// Writes just the current selection to a new WAV in the remembered export folder (a directory
    /// picker runs the first time). Auto-named; doesn't touch the loaded clip.
    func exportSelection(bits: BitDepthOption) async {
        guard let clip, let sel = selection, !sel.isEmpty else { return }
        let range = clip.clampedRange(sel)
        guard !range.isEmpty else { return }

        guard let folder = env.bookmarks.lastExportFolder() ?? pickExportFolder() else { return }

        let stem = source?.url.deletingPathExtension().lastPathComponent ?? "Selection"
        let name = Self.exportName(stem: stem, range: range, sampleRate: clip.sampleRate)
        let dest = FileOperator.uniqueDestination(in: folder, filename: name) {
            FileManager.default.fileExists(atPath: $0.path)
        }
        let piece = clip.cropped(to: range)

        isBusy = true
        defer { isBusy = false }
        switch await Self.writeFile(clip: piece, to: dest, bits: Self.resolve(bits)) {
        case .ok:
            lastExportURL = dest
            if let rootId = env.rootId(containing: dest) { await env.scanner.scan(rootId: rootId) }
        case .failure(let message):
            loadError = message
        case .url:
            break
        }
    }

    private func pickExportFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        panel.message = "Choose a folder to export selections into."
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        env.bookmarks.rememberExportFolder(url)
        return url
    }

    nonisolated static func exportName(stem: String, range: Range<Int>, sampleRate: Double) -> String {
        let start = Double(range.lowerBound) / max(1, sampleRate)
        let end = Double(range.upperBound) / max(1, sampleRate)
        return String(format: "%@ [%.2f-%.2f].wav", stem, start, end)
    }

    private static func replaceOnDisk(clip: AudioClip, originalURL: URL, rootURL: URL,
                                      bits: AudioFileIO.ResolvedBits) async -> WriteOutcome {
        let scoped = rootURL.startAccessingSecurityScopedResource()
        defer { if scoped { rootURL.stopAccessingSecurityScopedResource() } }
        let temp = originalURL.deletingLastPathComponent().appending(path: ".sieve-edit-\(UUID().uuidString).wav")
        let expectedFrames = clip.frameCount
        return await Task.detached(priority: .userInitiated) {
            do {
                try AudioFileIO.writeWAV(clip, to: temp, bits: bits)
                try AudioFileIO.validateFile(at: temp, expectedRate: clip.sampleRate,
                                             expectedChannels: max(1, clip.channelCount),
                                             minFrames: max(0, expectedFrames - 2))
                return .url(try AudioFileIO.replaceInPlace(originalURL: originalURL, tempURL: temp))
            } catch {
                try? FileManager.default.removeItem(at: temp)
                return .failure(describe(error))
            }
        }.value
    }

    private static func writeFile(clip: AudioClip, to dest: URL, bits: AudioFileIO.ResolvedBits) async -> WriteOutcome {
        let folder = dest.deletingLastPathComponent()
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        return await Task.detached(priority: .userInitiated) {
            do { try AudioFileIO.writeWAV(clip, to: dest, bits: bits); return .ok }
            catch { return .failure(describe(error)) }
        }.value
    }

    // MARK: Internals

    private func mutate(_ next: AudioClip, selection newSelection: (_ editedRange: Range<Int>) -> Range<Int>?) {
        guard let current = clip else { return }
        let edited = effectiveRange
        pushUndo(current)
        redo.removeAll()
        editSerial += 1
        clip = next
        selection = newSelection(edited).flatMap { Self.clamp($0, count: next.frameCount) }
        cursor = min(cursor, next.frameCount)
        rebuildDerived(for: next)
    }

    /// Rebuilds the zoom pyramid and list thumbnail off the main actor; the editor waveform falls
    /// back to raw scanning (`mip == nil`) until they land. `editSerial` is monotonic, so a rebuild
    /// from a superseded load or edit is discarded rather than clobbering the current state.
    private func rebuildDerived(for clip: AudioClip) {
        let serial = editSerial
        mip = nil
        thumbnail = nil
        Task {
            let built = await Task.detached(priority: .userInitiated) {
                (PeakMip(clip), clip.thumbnailSummary())
            }.value
            guard editSerial == serial else { return }
            mip = built.0
            thumbnail = built.1
        }
    }

    private func pushUndo(_ c: AudioClip) {
        undo.append(c)
        undoBytes += Self.bytes(c)
        while undoBytes > undoBudget, undo.count > 1 {
            undoBytes -= Self.bytes(undo.removeFirst())
        }
    }

    private func relativePath(of url: URL, under root: URL) -> String? {
        let file = url.standardizedFileURL.path
        var base = root.standardizedFileURL.path
        if !base.hasSuffix("/") { base += "/" }
        guard file.hasPrefix(base) else { return nil }
        return String(file.dropFirst(base.count))
    }

    private static func bytes(_ c: AudioClip) -> Int { c.frameCount * max(1, c.channelCount) * 4 }

    private static func clamp(_ r: Range<Int>, count: Int) -> Range<Int>? {
        let lo = max(0, min(r.lowerBound, count))
        let hi = max(lo, min(r.upperBound, count))
        return lo < hi ? lo..<hi : nil
    }

    private static func resolve(_ bits: BitDepthOption) -> AudioFileIO.ResolvedBits {
        switch bits {
        case .int16: return .int(16)
        case .int24, .keep: return .int(24)
        case .float32: return .float
        }
    }

    private static func bits(for row: SampleRow) -> BitDepthOption {
        if (row.formatName ?? "").localizedCaseInsensitiveContains("float") { return .float32 }
        switch row.bitDepth {
        case 16: return .int16
        case 24: return .int24
        default: return .int24
        }
    }
}
