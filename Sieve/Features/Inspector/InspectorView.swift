import SwiftUI

struct InspectorView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.openWindow) private var openWindow
    @Bindable var model: LibraryViewModel
    @AppStorage("inspectorTab") private var tab = InspectorTab.info

    enum InspectorTab: String { case info, edit }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("Info").tag(InspectorTab.info)
                Text("Edit").tag(InspectorTab.edit)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()

            switch tab {
            case .info:
                if let row = model.primarySelection {
                    SampleInspector(row: row, selectionCount: model.selection.count, selectedRows: model.selectedRows)
                        .id(row.id)
                } else {
                    ContentUnavailableView("No Selection", systemImage: "waveform",
                                           description: Text("Select a sample to see details."))
                }
            case .edit:
                if env.editor.windowOpen {
                    ContentUnavailableView {
                        Label("Editing in a Separate Window", systemImage: "macwindow")
                    } description: {
                        Text("The audio editor is open in its own window.")
                    } actions: {
                        Button("Bring Editor to Front") { openWindow(id: "audio-editor") }
                    }
                } else {
                    AudioEditorView(currentRow: model.primarySelection)
                }
            }
        }
    }
}

struct SampleInspector: View {
    @Environment(AppEnvironment.self) private var env
    let row: SampleRow
    let selectionCount: Int
    let selectedRows: [SampleRow]

    @State private var fullWaveform: WaveformSummary?
    @State private var zoom: Double = 1
    @State private var notes = ""
    @State private var newTag = ""
    @State private var notesTask: Task<Void, Never>?
    @State private var duplicateCount = 0

    private var store: AnnotationStore { AnnotationStore(database: env.database) }
    private var isCurrent: Bool { env.player.currentSampleId == row.id }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                waveformSection
                levelsRow
                metadataGrid
                Divider()
                actionButtons
                ratingRow
                tagsSection
                notesSection
                Divider()
                pathSection
            }
            .padding(14)
        }
        .task(id: row.id) { await load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(row.filename).font(.headline).lineLimit(2)
            if selectionCount > 1 {
                Text("\(selectionCount) selected — edits apply to this one").font(.caption).foregroundStyle(.secondary)
            }
            if duplicateCount > 1 {
                Label("\(duplicateCount) identical copies", systemImage: "doc.on.doc")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private var waveformSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                ScrollView(.horizontal) {
                    let summary = fullWaveform ?? row.waveform.flatMap(WaveformSummary.init(encoded:))
                    let width = geo.size.width * zoom
                    WaveformView(
                        summary: summary,
                        playhead: isCurrent && env.player.duration > 0 ? env.player.position / env.player.duration : nil,
                        showGrid: true
                    )
                    .frame(width: width, height: 120)
                    .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                    .highPriorityGesture(
                        DragGesture(minimumDistance: 0)
                            .onEnded { value in
                                seek(max(0, min(1, value.location.x / max(1, width))))
                            }
                    )
                }
                .scrollIndicators(.automatic)
                .scrollDisabled(zoom <= 1.0001)
            }
            .frame(height: 120)
            HStack {
                Button {
                    env.togglePreview(row)
                } label: {
                    Image(systemName: isCurrent && env.player.isPlaying ? "stop.fill" : "play.fill")
                }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(row.status != .present)
                Text(isCurrent ? Fmt.duration(env.player.position) : "0.00s").monospacedDigit().font(.caption)
                Text("/ \(Fmt.duration(row.durationSec))").monospacedDigit().font(.caption).foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary)
                Slider(value: $zoom, in: 1...32).frame(width: 110)
                    .onChange(of: zoom) { _, _ in Task { await regenerateWaveform() } }
                Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary)
            }
        }
    }

    private var levelsRow: some View {
        HStack(spacing: 16) {
            levelTile("Peak", Fmt.db(row.peakDb))
            levelTile("RMS", Fmt.db(row.rmsDb))
            if let clip = row.clippedSamples, clip > 0 {
                VStack(alignment: .leading) {
                    Text("Clipping").font(.caption2).foregroundStyle(.secondary)
                    Text("\(clip) samples").font(.caption).bold().foregroundStyle(.red)
                }
            } else {
                levelTile("Clipping", "none")
            }
        }
    }

    private func levelTile(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption).bold().monospacedDigit()
        }
    }

    private var metadataGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            metaRow("Format", row.formatName ?? "Unsupported")
            metaRow("Sample rate", Fmt.sampleRate(row.sampleRate))
            metaRow("Channels", Fmt.channels(row.channels))
            metaRow("Bit depth", row.bitDepth.map { "\($0)-bit" } ?? "–")
            metaRow("Duration", Fmt.duration(row.durationSec))
            metaRow("Size", Fmt.bytes(row.fileSize))
            metaRow("BPM", row.bpm.map { $0.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int($0))" : String(format: "%.1f", $0) } ?? "–")
            metaRow("Key", row.musicalKey ?? "–")
            metaRow("Modified", row.modifiedAt.formatted(date: .abbreviated, time: .shortened))
        }
        .font(.caption)
    }

    private func metaRow(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).foregroundStyle(.secondary)
            Text(v).textSelection(.enabled)
        }
    }

    private var ratingRow: some View {
        HStack {
            StarRatingView(rating: row.rating ?? 0, onChange: { r in
                Task { try? await store.setRating(r, for: row) }
            }, size: 16)
            Spacer()
            Button {
                Task { try? await store.setFavorite(!(row.isFavorite ?? false), for: row) }
            } label: {
                Image(systemName: row.isFavorite == true ? "heart.fill" : "heart")
                    .foregroundStyle(row.isFavorite == true ? .pink : .secondary)
            }
            .buttonStyle(.plain)
        }
    }

    private var tagsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tags").font(.caption).foregroundStyle(.secondary)
            FlowLayout(spacing: 4) {
                ForEach(row.tags, id: \.self) { tag in
                    HStack(spacing: 2) {
                        Text(tag)
                        Button { Task { try? await store.removeTag(named: tag, from: row) } } label: {
                            Image(systemName: "xmark").font(.system(size: 8))
                        }.buttonStyle(.plain)
                    }
                    .font(.caption)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.15), in: Capsule())
                }
            }
            TextField("Add tag…", text: $newTag)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    let targets = selectionCount > 1 ? selectedRows : [row]
                    let name = newTag
                    newTag = ""
                    Task { try? await store.addTag(named: name, to: targets) }
                }
        }
    }

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Notes").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $notes)
                .font(.body)
                .frame(minHeight: 60)
                .scrollContentBackground(.hidden)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                .onChange(of: notes) { _, new in
                    notesTask?.cancel()
                    notesTask = Task {
                        try? await Task.sleep(for: .milliseconds(400))
                        guard !Task.isCancelled else { return }
                        try? await store.setNotes(new, for: row)
                    }
                }
        }
    }

    private var actionButtons: some View {
        HStack {
            Button("Reveal in Finder") { env.revealInFinder(row) }
            Button(env.audioEditorName.map { "Open in \($0)" } ?? "Open in Audio Editor…") {
                env.openInAudioEditor(row)
            }
            .help(env.audioEditorName == nil ? "Pick an audio editor, then send this sample to it" : "Send this sample to \(env.audioEditorName!)")
        }
        .controlSize(.small)
        .disabled(row.status != .present)
    }

    private var pathSection: some View {
        Text(row.relativePath).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(3)
    }

    // MARK: Actions

    private func load() async {
        notes = (try? await store.notes(for: row)) ?? ""
        if let hash = row.contentHash {
            duplicateCount = (try? await env.database.reader.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sample WHERE status='present' AND COALESCE(audioHash,fileHash) = ?", arguments: [hash])
            }) ?? 0
        }
        await regenerateWaveform()
    }

    private func regenerateWaveform() async {
        guard row.status == .present, let root = env.rootURL(for: row.rootId), let url = env.fileURL(for: row) else { return }
        let buckets = min(16_384, Int(1024 * zoom))
        let summary = await Task.detached(priority: .userInitiated) {
            withSecurityScope(root) { try? WaveformGenerator.summary(url: url, buckets: buckets) }
        }.value
        if let summary { fullWaveform = summary }
    }

    private func seek(_ fraction: Double) {
        env.seek(row, toFraction: fraction)
    }
}

/// Minimal wrapping layout for tag chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 300
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > width, x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
        return CGSize(width: width, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
    }
}
