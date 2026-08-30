import SwiftUI

/// The audio editor UI. Rendered both in the inspector's Edit tab and, at a larger size, in the
/// pop-out editor window — both share `env.editor` (one `EditorSession`).
struct AudioEditorView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.openWindow) private var openWindow

    /// The currently selected sample, so the Edit tab can load it on first appearance.
    /// `nil` in the pop-out window (which just shows whatever the session already has).
    var currentRow: SampleRow? = nil
    var showsPopOutButton = true

    @AppStorage("editorNormalizeDb") private var normalizeDb = -1.0

    @State private var zoom: Double = 1
    @State private var saveBits: BitDepthOption = .int24
    @State private var amplifyDb = 0.0
    @State private var preventClip = true
    @State private var showAmplify = false
    @State private var showReplaceConfirm = false

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
                Divider()
                operations
                saveRow
            }
        }
        .padding(10)
        .onAppear {
            session.retain(currentRow: currentRow)
            saveBits = session.source?.sourceBits ?? .int24
        }
        .onDisappear { session.release() }
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
            if showsPopOutButton {
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
            zoom: $zoom,
            playheadFrame: session.player.isPlaying ? session.player.playheadFrame : nil
        )
        .frame(minHeight: 130, maxHeight: .infinity)
    }

    private var transport: some View {
        HStack(spacing: 8) {
            Button { session.togglePlay() } label: {
                Image(systemName: session.player.isPlaying ? "stop.fill" : "play.fill")
            }
            Button { session.playSelection() } label: { Image(systemName: "play.rectangle") }
                .help("Play selection").disabled(!session.hasSelection)
            Toggle(isOn: Binding(get: { session.looping }, set: { session.looping = $0 })) {
                Image(systemName: "repeat")
            }
            .toggleStyle(.button).help("Loop")

            Text(Fmt.duration(Double(session.player.playheadFrame) / max(1, session.sampleRate)))
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)

            Spacer()

            Button { zoom = max(1, zoom / 2) } label: { Image(systemName: "minus.magnifyingglass") }
                .disabled(zoom <= 1)
            Button("Fit") { zoom = 1 }
            Button { zoom = min(64, zoom * 2) } label: { Image(systemName: "plus.magnifyingglass") }
                .disabled(zoom >= 64)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
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
            Button("Save (Replace…)") { showReplaceConfirm = true }.disabled(!session.isDirty)
            Button("Revert") { Task { await session.revert() } }.disabled(!session.isDirty)
            Spacer()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}
