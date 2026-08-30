import SwiftUI
import UniformTypeIdentifiers

struct SampleListView: View {
    @Environment(AppEnvironment.self) private var env
    @Bindable var model: LibraryViewModel
    @AppStorage("autoPreview") private var autoPreview = true
    @State private var tableWidth: CGFloat = 900
    @State private var columnCustomization = TableColumnCustomization<SampleRow>()
    @State private var convertRequest: ConvertRequest?

    private struct ConvertRequest: Identifiable {
        let id = UUID()
        let rows: [SampleRow]
    }

    // As the centre pane narrows, trailing columns drop off right-to-left until only the
    // waveform is left. Each pair is (customizationID, table width in pt at which it appears).
    private static let responsiveColumns: [(id: String, minWidth: CGFloat)] = [
        ("name", 280),
        ("duration", 360),
        ("rate", 430),
        ("bits", 470),
        ("rating", 560),
        ("tags", 680),
        ("size", 780),
    ]

    var body: some View {
        VStack(spacing: 0) {
            FilterBar(model: model)
            Divider()
            Table(model.rows, selection: $model.selection, columnCustomization: $columnCustomization) {
                TableColumn("Waveform") { row in
                    WaveformCell(row: row) { fraction in
                        model.selection = [row.id]
                        env.seek(row, toFraction: fraction)
                    }
                }
                .width(min: 80, ideal: 240)
                .customizationID("waveform")
                .disabledCustomizationBehavior(.visibility)

                TableColumn("Name") { row in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            if env.player.currentSampleId == row.id && env.player.isPlaying {
                                Image(systemName: "speaker.wave.2.fill").foregroundStyle(.tint).font(.caption)
                            }
                            Text(row.filename).lineLimit(1)
                            if row.status != .present {
                                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).font(.caption)
                                    .help(row.status == .missing ? "File is missing" : "Volume not mounted")
                            }
                        }
                        Text(row.parentDir.isEmpty ? (model.root(for: row.rootId)?.name ?? "") : row.parentDir)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .draggable(SampleDrag(id: row.id,
                                          fileURL: env.fileURL(for: row),
                                          rootURL: env.rootURL(for: row.rootId),
                                          filename: row.filename))
                }
                .width(min: 140, ideal: 260)
                .customizationID("name")

                TableColumn("Duration") { row in Text(Fmt.duration(row.durationSec)).monospacedDigit() }
                    .width(60).customizationID("duration")
                TableColumn("Rate") { row in Text(Fmt.sampleRate(row.sampleRate)) }
                    .width(60).customizationID("rate")
                TableColumn("Bits") { row in Text(row.bitDepth.map(String.init) ?? "–") }
                    .width(32).customizationID("bits")
                TableColumn("Rating") { row in
                    StarRatingView(rating: row.rating ?? 0) { r in
                        Task { try? await AnnotationStore(database: env.database).setRating(r, for: row) }
                    }
                }
                .width(76).customizationID("rating")
                TableColumn("Tags") { row in
                    Text(row.tags.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .width(min: 60, ideal: 140).customizationID("tags")
                TableColumn("Size") { row in Text(Fmt.bytes(row.fileSize)).monospacedDigit() }
                    .width(64).customizationID("size")
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                tableWidth = width
                applyResponsiveColumns(width: width)
            }
            .contextMenu(forSelectionType: Int64.self) { ids in
                let rows = model.rows.filter { ids.contains($0.id) }
                if let first = rows.first {
                    Button("Play") { env.preview(first) }
                    Button("Reveal in Finder") { env.revealInFinder(first) }
                    Button(env.audioEditorName.map { "Open in \($0)" } ?? "Open in Audio Editor…") {
                        env.openInAudioEditor(first)
                    }
                    .disabled(first.status != .present)
                    Divider()
                    Button(rows.allSatisfy { $0.isFavorite == true } ? "Remove from Favorites" : "Add to Favorites") {
                        let fav = !(rows.allSatisfy { $0.isFavorite == true })
                        Task { for r in rows { try? await AnnotationStore(database: env.database).setFavorite(fav, for: r) } }
                    }
                    Divider()
                    Button("Convert Sample Rate / Bit Depth…") {
                        convertRequest = ConvertRequest(rows: rows)
                    }
                    .disabled(!rows.contains { $0.status == .present })
                }
            } primaryAction: { ids in
                if let id = ids.first, let row = model.rows.first(where: { $0.id == id }) { env.preview(row) }
            }
            .onKeyPress(.space) {
                if let row = model.primarySelection { env.togglePreview(row); return .handled }
                return .ignored
            }
            .onChange(of: model.selection) { _, new in
                guard autoPreview, new.count == 1, let row = model.primarySelection, row.status == .present else { return }
                // Don't restart from the top if this sample is already loaded (e.g. the user
                // just clicked its waveform to seek).
                guard env.player.currentSampleId != row.id else { return }
                env.preview(row)
            }
            .draggable(model.selection) // placeholder; per-row drag below
            .overlay {
                if model.rows.isEmpty { emptyState }
            }
            .sheet(item: $convertRequest) { req in
                BatchConvertSheet(model: model, rows: req.rows)
            }
            Divider()
            statusBar
        }
    }

    private func applyResponsiveColumns(width: CGFloat) {
        for column in Self.responsiveColumns {
            let wanted: Visibility = width >= column.minWidth ? .visible : .hidden
            if columnCustomization[visibility: column.id] != wanted {
                columnCustomization[visibility: column.id] = wanted
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(model.roots.isEmpty ? "No Folders Yet" : "No Samples", systemImage: "waveform.slash")
        } description: {
            Text(model.roots.isEmpty ? "Add a folder of samples to start indexing." : "Nothing matches the current filter.")
        } actions: {
            if model.roots.isEmpty {
                Button("Add Folder…") { Task { await env.addRootViaPanel() } }
            }
        }
    }

    private var statusBar: some View {
        HStack {
            Text("\(model.rows.count) samples").font(.caption).foregroundStyle(.secondary)
            if !model.selection.isEmpty {
                Text("· \(model.selection.count) selected").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            ScanProgressView()
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
    }
}

extension Set<Int64>: @retroactive Transferable {
    public static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .data)
    }
}

extension Int64: @retroactive Transferable {
    public static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .data)
    }
}

/// Drag payload for a sample row: exports the real audio file (for Finder / other apps) and,
/// as a fallback representation, the sample id (used by the sidebar tag drop targets).
struct SampleDrag: Transferable {
    let id: Int64
    let fileURL: URL?
    let rootURL: URL?
    let filename: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .audio) { drag in
            guard let fileURL = drag.fileURL, let rootURL = drag.rootURL else {
                throw CocoaError(.fileNoSuchFile)
            }
            // Keep the root readable while the receiver copies the file, then rebalance.
            if rootURL.startAccessingSecurityScopedResource() {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(20))
                    rootURL.stopAccessingSecurityScopedResource()
                }
            }
            return SentTransferredFile(fileURL)
        }
        .suggestedFileName { $0.filename }

        ProxyRepresentation(exporting: { $0.id })
    }
}

struct WaveformCell: View {
    @Environment(AppEnvironment.self) private var env
    let row: SampleRow
    var onSeek: ((Double) -> Void)? = nil

    var body: some View {
        let summary = env.waveformCache.summary(id: row.id, data: row.waveform)
        let playhead: Double? = (env.player.currentSampleId == row.id && env.player.duration > 0)
            ? env.player.position / env.player.duration : nil
        GeometryReader { geo in
            WaveformView(summary: summary, playhead: playhead) { x in
                onSeek?(max(0, min(1, x / max(1, geo.size.width))))
            }
            .padding(.vertical, 2)
        }
        .frame(height: 36)
        .frame(maxWidth: .infinity)
        .draggable(sampleDrag)
    }

    private var sampleDrag: SampleDrag {
        SampleDrag(id: row.id,
                   fileURL: env.fileURL(for: row),
                   rootURL: env.rootURL(for: row.rootId),
                   filename: row.filename)
    }
}

struct FilterBar: View {
    @Bindable var model: LibraryViewModel

    var body: some View {
        // ViewThatFits keeps the bar right-aligned when there's room, and falls back to a
        // horizontally scrollable row when the centre pane is narrow — so the filter bar
        // never forces the window wider while a divider is dragged.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                controls
                Spacer(minLength: 8)
                sortPicker
            }
            .padding(8)

            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    controls
                    sortPicker
                }
                .padding(8)
            }
            .scrollIndicators(.hidden)
        }
    }

    @ViewBuilder private var controls: some View {
        TextField("Search names and paths", text: $model.searchText)
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 90, idealWidth: 220, maxWidth: 320)
        Picker("Rating", selection: $model.filter.minRating) {
            Text("Any rating").tag(0)
            ForEach(1...5, id: \.self) { Text("\($0)+ ★").tag($0) }
        }
        .frame(width: 120)
        Menu {
            ForEach(Queries.audioExtensions, id: \.self) { ext in
                Toggle(ext.uppercased(), isOn: Binding(
                    get: { model.filter.extensions.contains(ext) },
                    set: { on in if on { model.filter.extensions.insert(ext) } else { model.filter.extensions.remove(ext) } }))
            }
            if !model.filter.extensions.isEmpty {
                Divider()
                Button("Clear") { model.filter.extensions = [] }
            }
        } label: {
            Text(model.filter.extensions.isEmpty ? "All formats" : model.filter.extensions.sorted().map { $0.uppercased() }.joined(separator: ","))
        }
        .frame(width: 130)
    }

    private var sortPicker: some View {
        HStack(spacing: 4) {
            Picker("Sort", selection: sortBinding) {
                ForEach(SampleSort.allCases) { Text($0.label).tag($0) }
            }
            .frame(width: 130)
            Button {
                model.filter.sortAscending.toggle()
            } label: {
                Image(systemName: model.filter.sortAscending ? "arrow.up" : "arrow.down")
            }
            .buttonStyle(.borderless)
            .help(model.filter.sortAscending ? "Ascending — click to reverse" : "Descending — click to reverse")
        }
    }

    private var sortBinding: Binding<SampleSort> {
        Binding(
            get: { model.filter.sort },
            set: { model.filter.select($0) }
        )
    }
}
