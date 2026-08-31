import AppKit
import SwiftUI

/// The audio editor UI. Rendered both in the inspector's Edit tab and, at a larger size, in the
/// pop-out editor window — both share `env.editor` (one `EditorSession`).
struct AudioEditorView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.openWindow) private var openWindow

    /// The currently selected sample, so the Edit tab can load it on first appearance.
    /// `nil` in the pop-out window (which just shows whatever the session already has).
    var currentRow: SampleRow? = nil
    /// True for the standalone editor window; the inspector's inline copy leaves this false.
    var isPopOut = false

    @AppStorage("editorNormalizeDb") private var normalizeDb = -1.0
    @AppStorage("editorFloatOnTop") private var floatOnTop = true

    @State private var saveBits: BitDepthOption = .int24
    @State private var amplifyDb = 0.0
    @State private var preventClip = true
    @State private var showAmplify = false
    @State private var showReplaceConfirm = false
    @State private var showRecordingSaved = false
    @State private var showExportSaved = false

    private var session: EditorSession { env.editor }

    var body: some View {
        VStack(spacing: 8) {
            if session.isBusy && !session.hasClip {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let message = session.loadError, !session.hasClip {
                ContentUnavailableView("Can't Edit This File", systemImage: "waveform.slash",
                                       description: Text(message))
            } else if !session.hasClip {
                ContentUnavailableView("No Audio", systemImage: "waveform",
                                       description: Text("Select a sample to edit."))
            } else {
                header
                waveform
                transport
                recordingBanner
                Divider()
                operations
                saveRow
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: session.recorder.lastRecordingURL) { _, new in
            guard new != nil else { return }
            showRecordingSaved = true
            Task { try? await Task.sleep(for: .seconds(6)); showRecordingSaved = false }
        }
        .onChange(of: session.lastExportURL) { _, new in
            guard new != nil else { return }
            showExportSaved = true
            Task { try? await Task.sleep(for: .seconds(6)); showExportSaved = false }
        }
        .background {
            if isPopOut { WindowLevelSetter(level: floatOnTop ? .floating : .normal) }
        }
        .onAppear {
            if isPopOut { session.windowOpen = true }
            session.retain(currentRow: currentRow)
            saveBits = session.source?.sourceBits ?? .int24
        }
        .onDisappear {
            if isPopOut { session.windowOpen = false }
            session.release()
        }
        .onChange(of: session.source?.sampleId) { _, _ in
            saveBits = session.source?.sourceBits ?? saveBits
        }
        .popover(isPresented: $showAmplify) { amplifyPopover }
        .confirmationDialog("Replace the original file?", isPresented: $showReplaceConfirm, titleVisibility: .visible) {
            Button("Replace “\(session.source?.url.lastPathComponent ?? "file")”", role: .destructive) {
                Task { await session.saveReplacingOriginal(bits: saveBits) }
            }
        } message: {
            Text("This overwrites the original audio and can't be undone. Ratings, tags and notes are kept.")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    if session.isDirty {
                        Circle().fill(.orange).frame(width: 7, height: 7)
                    }
                    Text(session.source?.url.lastPathComponent ?? "").font(.headline).lineLimit(1)
                }
                Text(readout).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if session.isBusy { ProgressView().controlSize(.small) }
            if isPopOut {
                Button { floatOnTop.toggle() } label: {
                    Image(systemName: floatOnTop ? "pin.fill" : "pin")
                }
                .help(floatOnTop ? "Floating above other windows — click to stop"
                                 : "Click to keep this window above others")
            } else {
                Button { openWindow(id: "audio-editor") } label: {
                    Image(systemName: "macwindow.on.rectangle")
                }
                .help("Open the editor in a separate window")
            }
        }
    }

    private var readout: String {
        let rate = Fmt.sampleRate(session.sampleRate)
        let total = Fmt.duration(session.duration)
        if session.hasSelection {
            let selectionSeconds = Double(session.effectiveRange.count) / max(1, session.sampleRate)
            return "\(rate) · \(session.channelCount) ch · selected \(Fmt.duration(selectionSeconds)) of \(total)"
        }
        return "\(rate) · \(session.channelCount) ch · \(total)"
    }

    // MARK: Waveform + transport

    private var waveform: some View {
        EditorWaveformView(
            clip: session.clip ?? AudioClip(channels: [], sampleRate: 44_100),
            mip: session.mip,
            selection: Binding(get: { session.selection }, set: { session.selection = $0 }),
            playheadFrame: mirroredPlayhead,
            previewGainDb: Binding(get: { session.previewGainDb }, set: { session.setPreviewGain($0) }),
            onClickSeek: { session.setCursor($0) },
            onSelectionCommitted: { session.startPlayback() },   // jump playback to the new selection
            onApplyGain: { session.applyPreviewGain() },
            resetToken: session.source?.sampleId,
            showsTimeRuler: isPopOut
        )
        // Match the Info tab's 120 pt waveform inline; let the pop-out window use the room.
        .frame(height: isPopOut ? nil : 120)
        .frame(maxHeight: isPopOut ? .infinity : nil)
    }

    /// While playing: the editor's own playhead (or the list preview's, if that's what's playing
    /// this file). While stopped: the click cursor, so you can see where playback will start.
    private var mirroredPlayhead: Int? {
        if session.player.isPlaying { return session.player.playheadFrame }
        if env.player.currentSampleId == session.source?.sampleId, env.player.isPlaying,
           env.player.duration > 0, session.frameCount > 0 {
            return Int(env.player.position / env.player.duration * Double(session.frameCount))
        }
        return session.hasClip ? session.cursor : nil
    }

    private var transport: some View {
        HStack(spacing: 8) {
            Button { session.togglePlay() } label: {
                Image(systemName: session.player.isPlaying ? "stop.fill" : "play.fill")
            }
            .help(session.hasSelection ? "Play the selection" : "Play from the cursor")
            .modifier(SpaceToToggle(enabled: isPopOut))
            Toggle(isOn: Binding(get: { session.looping }, set: { session.looping = $0 })) {
                Image(systemName: "repeat")
            }
            .toggleStyle(.button)
            .help(session.hasSelection ? "Loop the selection" : "Loop")

            Text(Fmt.duration(Double(mirroredPlayhead ?? 0) / max(1, session.sampleRate)))
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)

            Spacer()

            recordControls
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    @ViewBuilder private var recordControls: some View {
        let recorder = session.recorder
        if recorder.isRecording {
            Image(systemName: "waveform", variableValue: Double(min(1, max(0, recorder.level))))
                .foregroundStyle(.red)
                .symbolEffect(.pulse, isActive: true)
            Text(Self.mmss(recorder.elapsed))
                .font(.caption).monospacedDigit().foregroundStyle(.red)
        }
        Button { session.toggleRecording() } label: {
            Image(systemName: recorder.isRecording ? "stop.fill" : "record.circle")
        }
        .tint(.red)
        .help(recorder.isRecording ? "Stop recording" : "Record the editor's playback to a new WAV")
    }

    @ViewBuilder private var recordingBanner: some View {
        if let error = session.recorder.lastError {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        } else if showRecordingSaved, let url = session.recorder.lastRecordingURL {
            savedLine("Saved", url)
        } else if showExportSaved, let url = session.lastExportURL {
            savedLine("Exported", url)
        }
    }

    private func savedLine(_ verb: String, _ url: URL) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text("\(verb) \(url.lastPathComponent)").font(.caption).lineLimit(1)
            Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                .buttonStyle(.link).controlSize(.small)
            Spacer()
        }
    }

    private static func mmss(_ t: TimeInterval) -> String {
        let s = Int(t.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: Operations

    private var operations: some View {
        ViewThatFits(in: .horizontal) {
            operationButtons
            ScrollView(.horizontal) { operationButtons }.scrollIndicators(.hidden)
        }
    }

    @ViewBuilder private var operationButtons: some View {
        HStack(spacing: 6) {
            Button("Trim") { session.trimToSelection() }.disabled(!session.hasSelection)
            Button("Delete") { session.deleteSelection() }.disabled(!session.hasSelection)
            Button("Silence") { session.silence() }
            Button("Normalize") { session.normalize(toDb: Float(normalizeDb)) }
            Button("Amplify…") { amplifyDb = 0; showAmplify = true }
            Button("Reverse") { session.reverse() }
            Button("Fade In") { session.fadeIn() }
            Button("Fade Out") { session.fadeOut() }
            Divider().frame(height: 16)
            Button("Cut") { session.cut() }.disabled(!session.hasSelection)
            Button("Copy") { session.copySelection() }.disabled(!session.hasSelection)
            Button("Paste") { session.paste() }.disabled(!session.hasClipboard)
            Divider().frame(height: 16)
            Button { session.undoEdit() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!session.canUndo)
            Button { session.redoEdit() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!session.canRedo)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.vertical, 2)
    }

    private var amplifyPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Amplify").font(.headline)
            HStack {
                Slider(value: $amplifyDb, in: -48...24)
                Text(String(format: "%+.1f dB", amplifyDb)).monospacedDigit().frame(width: 72, alignment: .trailing)
            }
            Toggle("Prevent clipping", isOn: $preventClip)
            HStack {
                Spacer()
                Button("Cancel") { showAmplify = false }
                Button("Apply") {
                    session.amplify(db: clippedGain(Float(amplifyDb)))
                    showAmplify = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    private func clippedGain(_ db: Float) -> Float {
        guard preventClip, let clip = session.clip else { return db }
        let peak = clip.peakLinear(in: session.effectiveRange)
        guard peak > 0 else { return db }
        return min(db, 20 * log10(1 / peak))
    }

    // MARK: Save

    private var saveRow: some View {
        HStack(spacing: 8) {
            Picker("", selection: $saveBits) {
                Text("16-bit").tag(BitDepthOption.int16)
                Text("24-bit").tag(BitDepthOption.int24)
                Text("32-bit float").tag(BitDepthOption.float32)
            }
            .labelsHidden().frame(width: 116)

            Button("Save As New…") { Task { await session.saveAsNewFile(bits: saveBits) } }
            Button("Export Selection…") { Task { await session.exportSelection(bits: saveBits) } }
                .disabled(!session.hasSelection)
            Button("Save (Replace…)") { showReplaceConfirm = true }.disabled(!session.isDirty)
            Button("Revert") { Task { await session.revert() } }.disabled(!session.isDirty)
            Spacer()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}

/// Binds the Space key to the Play/Stop button — only in the pop-out window, where there's no
/// competing Space handler (the list's preview shortcut lives in the main window).
private struct SpaceToToggle: ViewModifier {
    let enabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.keyboardShortcut(.space, modifiers: [])
        } else {
            content
        }
    }
}

/// Sets the hosting window's level (e.g. `.floating` to keep it above other windows).
private struct WindowLevelSetter: NSViewRepresentable {
    var level: NSWindow.Level

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        let level = level
        DispatchQueue.main.async { nsView.window?.level = level }
    }
}
