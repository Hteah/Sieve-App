import AppKit
import SwiftUI
import UniformTypeIdentifiers

// `fetchSampleRows`, `SampleDropCatcher` live in SidebarView.swift (same module).

struct SampleListView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.palette) private var palette
    @Bindable var model: LibraryViewModel
    /// Set by `ContentView` while a sidebar/inspector toggle animates: recalc columns only once
    /// the width settles. A manual divider drag / window resize leaves this false and updates live.
    var paneToggleActive = false
    @AppStorage("autoPreview") private var autoPreview = true
    /// "Auto-preview browsing" mode (toggled from the pane bar): any click on a row, and every
    /// arrow-key move, previews the file from the start; the waveform stops seeking to the tap.
    @AppStorage("browsePreview") private var browsePreview = false
    @AppStorage(QuickTags.storageKey) private var quickTagSlotsJSON = ""
    @State private var columnCustomization = TableColumnCustomization<SampleRow>()
    /// Latest list width seen while a pane toggle is animating; applied once the toggle settles.
    @State private var deferredWidth: CGFloat?
    @State private var convertRequest: ConvertRequest?
    @State private var moveRequest: MoveRequest?
    @State private var deleteRequest: DeleteRequest?
    @State private var listDropTargeted = false
    // A tap on a row's waveform runs a DragGesture inside the Table cell, which knocks
    // keyboard focus off the Table — so the next Space press lands nowhere (or in the
    // search field). Re-assert focus here after any row/waveform interaction.
    @FocusState private var listFocused: Bool

    private struct ConvertRequest: Identifiable {
        let id = UUID()
        let rows: [SampleRow]
    }

    private struct MoveRequest: Identifiable {
        let id = UUID()
        let rows: [SampleRow]
        let destination: URL
    }

    private struct DeleteRequest: Identifiable {
        let id = UUID()
        let rows: [SampleRow]
        let permanent: Bool
    }

    // As the centre pane narrows, trailing columns drop off right-to-left until only the
    // waveform is left. Each pair is (customizationID, table width in pt at which it appears).
    private static let responsiveColumns: [(id: String, minWidth: CGFloat)] = [
        ("name", 280),
        ("format", 330),
        ("duration", 390),
        ("rate", 450),
        ("bits", 490),
        ("rating", 580),
        ("quickTag", 630),
        ("size", 300),   // low threshold: keep Size visible at any real pane width
    ]

    var body: some View {
        VStack(spacing: 0) {
            FilterBar(model: model)
                .themedChrome(palette)
            Rectangle().fill(palette.divider).frame(height: 1)
            sampleTable
                .onKeyPress(.delete, phases: .down, action: handleDeleteKey)
                .sheet(item: $deleteRequest) { req in
                    DeleteSamplesSheet(model: model, rows: req.rows, permanent: req.permanent)
                }
            Rectangle().fill(palette.divider).frame(height: 1)
            statusBar
                .themedChrome(palette)
        }
        .background(palette.surface)
    }

    /// The table and its full modifier stack, pulled out of `body` so each stays inside the
    /// Swift type-checker's budget.
    private var sampleTable: some View {
        Table(model.rows, selection: $model.selection, sortOrder: sortComparators,
              columnCustomization: $columnCustomization) {
                TableColumn("Waveform") { row in
                    WaveformCell(row: row) { fraction in
                        model.selection = [row.id]
                        if browsePreview {
                            env.preview(row)                       // browse mode: always from the top
                        } else {
                            env.seek(row, toFraction: fraction)
                        }
                        listFocused = true
                    }
                }
                .width(min: 80, ideal: 240)
                .customizationID("waveform")
                .disabledCustomizationBehavior(.visibility)

                TableColumn("Name", value: \.filenameSortKey) { row in
                    nameCell(row)
                }
                .width(min: 140, ideal: 260)
                .customizationID("name")

                TableColumn("Format", value: \.ext) { row in
                    Text(row.ext.uppercased()).foregroundStyle(.secondary)
                }
                .width(52).customizationID("format")

                TableColumn("Duration", value: \.durationSortKey) { row in
                    Text(Fmt.duration(row.durationSec)).monospacedDigit()
                }
                .width(60).customizationID("duration")
                TableColumn("Rate", value: \.rateSortKey) { row in
                    Text(Fmt.sampleRate(row.sampleRate))
                }
                .width(60).customizationID("rate")
                TableColumn("Bits", value: \.bitsSortKey) { row in
                    Text(row.bitDepth.map { "\($0)" } ?? "–")
                }
                .width(32).customizationID("bits")
                TableColumn("Rating", value: \.ratingSortKey) { row in
                    StarRatingView(rating: row.rating ?? 0) { r in
                        Task { try? await AnnotationStore(database: env.database).setRating(r, for: row) }
                    }
                }
                .width(76).customizationID("rating")
                TableColumn("Quick Tag") { row in
                    let slots = QuickTags.load(quickTagSlotsJSON)
                    // The indicator is drawn as plain cell content: AppKit renders a menu's
                    // label, and it drops the custom-drawn oscillator glyphs (text/SF Symbols
                    // only). The assign menu sits on top with a clear label so a click still
                    // opens it.
                    ZStack(alignment: .leading) {
                        QuickTagIndicator(mask: row.quickTags ?? 0, slots: slots)
                            .allowsHitTesting(false)
                        Menu {
                            ForEach(0..<QuickTags.count, id: \.self) { i in
                                Toggle(isOn: Binding(
                                    get: { QuickTags.isSet(row.quickTags ?? 0, i) },
                                    set: { _ in Task { try? await AnnotationStore(database: env.database).toggleQuickTag(i, for: [row]) } })) {
                                    QuickTagMenuLabel(slots: slots, index: i)
                                }
                            }
                            Divider()
                            Button("None") {
                                Task { try? await AnnotationStore(database: env.database).setQuickTagMask(0, for: row) }
                            }
                            .disabled((row.quickTags ?? 0) == 0)
                        } label: {
                            Color.clear.contentShape(Rectangle())
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .width(min: 60, ideal: 96, max: 160).customizationID("quickTag")
                TableColumn("Size", value: \.fileSize) { row in
                    Text(Fmt.bytes(row.fileSize)).monospacedDigit()
                }
                .width(min: 64, ideal: 80).customizationID("size")
            }
            // SwiftUI's Table can't recolour the every-other-row stripe, only toggle it — so it
            // is turned off and every row shows `surface`.
            .alternatingRowBackgrounds(.disabled)
            // Re-sorting reshuffles nearly every row; diffing 800+ scrambled rows is what
            // stalled the UI. Keying the table to the sort makes SwiftUI rebuild it once
            // (rendering only the visible rows) instead. Cost: scroll jumps to the top.
            .id(sortToken)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                // During a sidebar/inspector toggle the list width animates across the responsive
                // column thresholds; toggling `Table` column visibility mid-slide forces a
                // re-layout that visibly stalls the animation (worst at narrow widths). Hold the
                // width and apply it once the toggle settles; live for divider drags / resizes.
                if paneToggleActive {
                    deferredWidth = width
                } else {
                    applyResponsiveColumns(width: width)
                }
            }
            .onChange(of: paneToggleActive) { _, active in
                guard !active, let width = deferredWidth else { return }
                deferredWidth = nil
                applyResponsiveColumns(width: width)
            }
            .contextMenu(forSelectionType: Int64.self) { ids in
                rowMenu(for: model.rows.filter { ids.contains($0.id) })
            } primaryAction: { ids in
                if let id = ids.first, let row = model.rows.first(where: { $0.id == id }) { env.preview(row) }
                listFocused = true
            }
            .focused($listFocused)
            .onKeyPress(.space) {
                // Play / pause / resume, like the wave editor: Space pauses a running
                // preview in place, and Space again resumes it from the same spot. With
                // nothing playing — or a different row now selected — it starts the
                // selected row from the top.
                let row = model.primarySelection
                if env.player.isPlaying {
                    env.player.pause()
                } else if env.player.isPaused, let row, row.id == env.player.currentSampleId {
                    env.player.resume()
                } else if let row {
                    env.preview(row)
                } else {
                    return .ignored
                }
                return .handled
            }
            .onKeyPress(.escape) {
                // Esc fully stops (and forgets the playhead), so the next Space starts over.
                guard env.player.isPlaying || env.player.isPaused else { return .ignored }
                env.player.stop()
                return .handled
            }
            .onChange(of: model.selection) { _, new in
                guard browsePreview || autoPreview,
                      new.count == 1, let row = model.primarySelection, row.status == .present else { return }
                // Don't restart from the top if this sample is already loaded (e.g. the user
                // just clicked its waveform to seek).
                guard env.player.currentSampleId != row.id else { return }
                env.preview(row)
            }
            .draggable(model.selection) // placeholder; per-row drag below
            .overlay {
                if model.rows.isEmpty { emptyState }
            }
            // Drop samples (from this window or another) onto the list to move them into the
            // folder this window is scoped to. Catcher sits behind the Table.
            .background {
                if dropScopeFolder != nil {
                    SampleDropCatcher(onTargeted: { listDropTargeted = $0 }, onDrop: handleListDrop)
                }
            }
            .overlay {
                if listDropTargeted {
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .padding(1)
                        .allowsHitTesting(false)
                }
            }
            .sheet(item: $convertRequest) { req in
                BatchConvertSheet(model: model, rows: req.rows)
            }
            .sheet(item: $moveRequest) { req in
                MoveToFolderSheet(model: model, rows: req.rows, destination: req.destination)
            }
            .themedSurface(palette)
    }

    /// Changes only when the sort field or direction changes, so the table rebuilds then and
    /// nowhere else (selection, rescans, tag edits still update in place).
    private var sortToken: String {
        "\(model.filter.sort.rawValue)-\(model.filter.sortAscending)"
    }

    /// Reflects `model.filter` into the table header's sort indicator and back. Clicking a new
    /// column snaps to that field's default direction (`select`); clicking the active column
    /// flips it. The toolbar Sort menu writes the same `model.filter`, so the two stay in sync.
    /// SwiftUI never sorts `model.rows` itself — the visible order comes from the SQL query the
    /// `model.filter` change triggers — so these comparators only carry the header state.
    private var sortComparators: Binding<[KeyPathComparator<SampleRow>]> {
        Binding(
            get: {
                let order: SortOrder = model.filter.sortAscending ? .forward : .reverse
                let kp: KeyPathComparator<SampleRow> = switch model.filter.sort {
                case .name, .path, .modified: KeyPathComparator(\.filenameSortKey, order: order)
                case .duration: KeyPathComparator(\.durationSortKey, order: order)
                case .size: KeyPathComparator(\.fileSize, order: order)
                case .rating: KeyPathComparator(\.ratingSortKey, order: order)
                case .rate: KeyPathComparator(\.rateSortKey, order: order)
                case .bits: KeyPathComparator(\.bitsSortKey, order: order)
                case .format: KeyPathComparator(\.ext, order: order)
                }
                return [kp]
            },
            set: { new in
                guard let c = new.first else { return }
                let kp = c.keyPath as AnyKeyPath
                let field: SampleSort
                if kp == \SampleRow.durationSortKey { field = .duration }
                else if kp == \SampleRow.rateSortKey { field = .rate }
                else if kp == \SampleRow.bitsSortKey { field = .bits }
                else if kp == \SampleRow.ratingSortKey { field = .rating }
                else if kp == \SampleRow.fileSize { field = .size }
                else if kp == \SampleRow.ext { field = .format }
                else { field = .name }
                if field == model.filter.sort {
                    model.filter.sortAscending = (c.order == .forward)
                } else {
                    model.filter.select(field)
                }
            }
        )
    }

    @ViewBuilder
    private func nameCell(_ row: SampleRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                if (env.player.currentSampleId == row.id && env.player.isPlaying)
                    || env.editor.playingSampleId == row.id {
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
        // `.draggable` on a Table cell swallows the click that would select the row, so select
        // it here — unless a modifier means the user is extending the native shift/⌘ selection.
        .simultaneousGesture(TapGesture().onEnded {
            if NSEvent.modifierFlags.isDisjoint(with: [.shift, .command]) {
                model.selection = [row.id]
            }
        })
        .draggable(SampleDrag(id: row.id,
                              fileURL: env.fileURL(for: row),
                              rootURL: env.rootURL(for: row.rootId),
                              filename: row.filename))
    }

    /// Shows/hides trailing `Table` columns for the current list width. Not called while a pane
    /// toggle animates (see `.onGeometryChange` above) — a column-visibility change forces a full
    /// table re-layout that would stall the slide.
    private func applyResponsiveColumns(width: CGFloat) {
        for column in Self.responsiveColumns {
            let wanted: Visibility = width >= column.minWidth ? .visible : .hidden
            if columnCustomization[visibility: column.id] != wanted {
                columnCustomization[visibility: column.id] = wanted
            }
        }
    }

    /// The root the list is scoped to, when that root is currently unavailable (volume unmounted / moved).
    private var unavailableScopedRoot: Root? {
        guard case .root(let id) = model.filter.scope, let root = model.root(for: id),
              !root.isAvailable else { return nil }
        return root
    }

    @ViewBuilder
    private var emptyState: some View {
        if let root = unavailableScopedRoot, let id = root.id {
            ContentUnavailableView {
                Label("Volume Not Mounted", systemImage: "externaldrive.badge.questionmark")
            } description: {
                Text("Reconnect the drive, or relink \u{201C}\(root.name)\u{201D} to its new location.")
            } actions: {
                Button("Relink…") { Task { await env.relinkRootViaPanel(rootId: id) } }
            }
        } else {
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
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Text("\(model.rows.count) samples").font(.caption).foregroundStyle(.secondary)
            if !model.selection.isEmpty {
                Text("· \(model.selection.count) selected").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            ScanProgressView()
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
    }

    /// ⌘⌫ moves the selected present rows to the Trash (through the same confirm sheet). Plain
    /// Delete is ignored — too easy to hit by accident.
    private func handleDeleteKey(_ press: KeyPress) -> KeyPress.Result {
        guard press.modifiers.contains(.command) else { return .ignored }
        let sel = model.rows.filter { model.selection.contains($0.id) && $0.status == .present }
        guard !sel.isEmpty else { return .ignored }
        deleteRequest = DeleteRequest(rows: sel, permanent: false)
        return .handled
    }

    /// The row context menu. Extracted from `body` so the `Table` expression stays type-checkable.
    @ViewBuilder
    private func rowMenu(for rows: [SampleRow]) -> some View {
        if let first = rows.first {
            let hasPresent = rows.contains { $0.status == .present }
            Button("Reveal in Finder") { env.revealInFinder(first) }
            Button("Open in External Editor") { env.openInAudioEditor(first) }
                .help(env.audioEditorName.map { "Send this sample to \($0)" }
                      ?? "Pick an external audio editor, then send this sample to it")
                .disabled(first.status != .present)
            Divider()
            Button(rows.allSatisfy { $0.isFavorite == true } ? "Remove from Favorites" : "Add to Favorites") {
                let fav = !(rows.allSatisfy { $0.isFavorite == true })
                Task { for r in rows { try? await AnnotationStore(database: env.database).setFavorite(fav, for: r) } }
            }
            Menu("Quick Tag") {
                let slots = QuickTags.load(quickTagSlotsJSON)
                ForEach(0..<QuickTags.count, id: \.self) { i in
                    let allOn = rows.allSatisfy { ($0.quickTags ?? 0) & QuickTags.mask(i) != 0 }
                    Button {
                        Task { try? await AnnotationStore(database: env.database).toggleQuickTag(i, for: rows) }
                    } label: {
                        if allOn {
                            Label(QuickTags.displayName(slots, i), systemImage: "checkmark")
                        } else {
                            QuickTagMenuLabel(slots: slots, index: i)
                        }
                    }
                }
                Divider()
                Button("None") {
                    Task { for r in rows { try? await AnnotationStore(database: env.database).setQuickTagMask(0, for: r) } }
                }
            }
            Divider()
            Button("Move to Folder…") { chooseMoveDestination(for: rows) }
                .disabled(!hasPresent)
            Button("Convert Sample Rate / Bit Depth…") { convertRequest = ConvertRequest(rows: rows) }
                .disabled(!hasPresent)
            Divider()
            Button("Move to Trash") { deleteRequest = DeleteRequest(rows: rows, permanent: false) }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(!hasPresent)
            Button("Delete Permanently…", role: .destructive) {
                deleteRequest = DeleteRequest(rows: rows, permanent: true)
            }
            .disabled(!hasPresent)
        }
    }

    /// The folder this window's list is scoped to, if it's a single root or sub-folder — the drop
    /// destination when samples are dragged onto the list. `here` filters out rows already there.
    private var dropScopeFolder: (dest: URL, here: (SampleRow) -> Bool)? {
        switch model.filter.scope {
        case .root(let id):
            guard let u = env.rootURL(for: id) else { return nil }
            return (u, { $0.rootId == id && $0.parentDir.isEmpty })
        case .folder(let rootId, let parentDir):
            guard let u = env.rootURL(for: rootId) else { return nil }
            return (u.appending(path: parentDir), { $0.rootId == rootId && $0.parentDir == parentDir })
        default:
            return nil
        }
    }

    /// Samples were dropped on the list — move them into the folder this window is scoped to.
    private func handleListDrop(_ ids: [Int64]) -> Bool {
        guard let (dest, here) = dropScopeFolder, !ids.isEmpty else { return false }
        Task { @MainActor in
            let rows = await fetchSampleRows(ids, from: env.database)
                .filter { $0.status == .present && !here($0) }
            guard !rows.isEmpty else { return }
            moveRequest = MoveRequest(rows: rows, destination: dest)
        }
        return true
    }

    /// Folder picker for "Move to Folder…"; on OK, stages a confirmation sheet.
    private func chooseMoveDestination(for rows: [SampleRow]) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Move Here"
        panel.message = "Choose a folder to move the selected samples into."
        if let last = env.bookmarks.lastMoveDestination() { panel.directoryURL = last }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        env.bookmarks.rememberMoveDestination(url)
        moveRequest = MoveRequest(rows: rows, destination: url)
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

/// Drag payload for a sample row: exports the real audio file (for Finder / other apps), and the
/// sample id **as plain text** so the sidebar's AppKit drop catchers can read it off the
/// pasteboard (SwiftUI's own `.dropDestination` on `List` rows loses the payload).
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

        ProxyRepresentation(exporting: { String($0.id) })
    }
}

struct WaveformCell: View {
    @Environment(AppEnvironment.self) private var env
    let row: SampleRow
    var onSeek: ((Double) -> Void)? = nil

    var body: some View {
        // Mirror the editor: if this row is the dirty file open in the editor, show its live
        // waveform and playhead instead of the indexed blob / preview player.
        let summary = env.editor.liveThumbnail(for: row.id)
            ?? env.waveformCache.summary(id: row.id, data: row.waveform)
        let playhead: Double? = {
            if env.player.currentSampleId == row.id, env.player.duration > 0 {
                return env.player.position / env.player.duration
            }
            if env.editor.playingSampleId == row.id { return env.editor.playheadFraction }
            return nil
        }()
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
    @Environment(AppEnvironment.self) private var env
    @Environment(\.palette) private var palette
    @Bindable var model: LibraryViewModel

    var body: some View {
        // Falls back to a horizontally scrollable row when the centre pane is too narrow for the
        // controls, so the filter bar never forces the window wider while a divider is dragged.
        // Sorting lives on the table column headers, not here.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                controls
                Spacer(minLength: 0)
            }
            .padding(8)

            ScrollView(.horizontal) {
                HStack(spacing: 10) { controls }
                    .padding(8)
            }
            .scrollIndicators(.hidden)
        }
    }

    @ViewBuilder private var controls: some View {
        // Plain field painted from the palette — `.roundedBorder` draws an AppKit fill that
        // can't be recoloured, so the search box would ignore the theme.
        TextField("Search names and paths", text: $model.searchText)
            .textFieldStyle(.plain)
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(palette.surface, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(palette.divider, lineWidth: 1))
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

        Toggle(isOn: Binding(get: { env.player.looping }, set: { env.player.looping = $0 })) {
            Label("Loop", systemImage: "repeat")
        }
        .toggleStyle(.button)
        .help(env.player.looping ? "Looping the preview — click to stop" : "Loop the previewed sample")
    }
}

/// Confirms and runs a "Move to Folder…" on the list selection, through the same audited
/// `FileOperator` the duplicates view uses: it re-checks each file, moves it, logs the op, and
/// re-paths the sample row if the destination is inside an indexed folder (so ratings/tags/notes
/// follow). Files that are missing or on an unmounted volume are skipped.
struct MoveToFolderSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: LibraryViewModel
    let rows: [SampleRow]
    let destination: URL

    @State private var phase: Phase = .confirm
    @State private var results: [FileOpResult] = []

    enum Phase { case confirm, working, done }

    private var eligible: [SampleRow] {
        rows.filter { $0.status == .present && (model.root(for: $0.rootId)?.isAvailable ?? false) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch phase {
            case .confirm: confirmView
            case .working: ProgressView("Moving…").frame(maxWidth: .infinity, minHeight: 80)
            case .done: doneView
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private var confirmView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Move \(eligible.count) file\(eligible.count == 1 ? "" : "s")").font(.headline)
            Text("to \u{201C}\(destination.lastPathComponent)\u{201D}")
                .font(.callout).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
            List(eligible) { s in
                HStack {
                    Text(s.filename)
                    Spacer()
                    Text("\(model.root(for: s.rootId)?.name ?? "") / \(s.parentDir)")
                        .foregroundStyle(.secondary).font(.caption)
                }
            }
            .frame(minHeight: 140, maxHeight: 300)
            Text("Files are moved on disk. Ratings, tags and notes follow. A name clash gets a \u{201C} (2)\u{201D} suffix.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Move") { run() }.keyboardShortcut(.defaultAction).disabled(eligible.isEmpty)
            }
        }
    }

    private var doneView: some View {
        let failed = results.filter { !$0.succeeded }
        return VStack(alignment: .leading, spacing: 12) {
            Text(failed.isEmpty
                 ? "Moved \(results.count) file\(results.count == 1 ? "" : "s")"
                 : "\(results.count - failed.count) moved, \(failed.count) failed")
                .font(.headline)
            if !failed.isEmpty {
                List(failed) { f in
                    VStack(alignment: .leading) {
                        Text(f.filename)
                        Text(f.error ?? "").font(.caption).foregroundStyle(.red)
                    }
                }
                .frame(minHeight: 100, maxHeight: 220)
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
    }

    private func run() {
        phase = .working
        let targets = eligible
        Task {
            let op = FileOperator(database: env.database, bookmarks: env.bookmarks)
            results = await op.perform(.move(destination: destination), on: targets)
            phase = .done
            // Rescan the folders we moved out of, plus the destination folder if it's indexed.
            var roots = Set(targets.map(\.rootId))
            if let destRoot = env.rootId(containing: destination) { roots.insert(destRoot) }
            for id in roots { await env.scanner.scan(rootId: id) }
        }
    }
}

/// Confirms and runs a Trash / Delete-Permanently on the list selection through the audited
/// `FileOperator` (re-checks size+mtime, logs to `file_op_log`, reconciles the index). Trash
/// leaves the row as `missing`; a permanent delete removes it. Missing / offline-volume rows
/// are skipped.
struct DeleteSamplesSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: LibraryViewModel
    let rows: [SampleRow]
    let permanent: Bool

    @State private var phase: Phase = .confirm
    @State private var results: [FileOpResult] = []

    enum Phase { case confirm, working, done }

    private var verb: String { permanent ? "Delete Permanently" : "Move to Trash" }

    private var eligible: [SampleRow] {
        rows.filter { $0.status == .present && (model.root(for: $0.rootId)?.isAvailable ?? false) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch phase {
            case .confirm: confirmView
            case .working: ProgressView(permanent ? "Deleting…" : "Moving to Trash…")
                    .frame(maxWidth: .infinity, minHeight: 80)
            case .done: doneView
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private var confirmView: some View {
        let total = eligible.reduce(0) { $0 + $1.fileSize }
        return VStack(alignment: .leading, spacing: 12) {
            Text("\(verb): \(eligible.count) file\(eligible.count == 1 ? "" : "s") (\(Fmt.bytes(total)))")
                .font(.headline)
            List(eligible) { s in
                HStack {
                    Text(s.filename)
                    Spacer()
                    Text("\(model.root(for: s.rootId)?.name ?? "") / \(s.parentDir)")
                        .foregroundStyle(.secondary).font(.caption)
                }
            }
            .frame(minHeight: 140, maxHeight: 300)
            if permanent {
                Label("This deletes the files from disk. It cannot be undone.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            } else {
                Text("Files go to the Trash (Finder\u{2019}s Put Back restores them). The samples leave your library; ratings, tags and notes are kept.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(verb, role: .destructive) { run() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(eligible.isEmpty)
            }
        }
    }

    private var doneView: some View {
        let failed = results.filter { !$0.succeeded }
        return VStack(alignment: .leading, spacing: 12) {
            Text(failed.isEmpty
                 ? "\(permanent ? "Deleted" : "Trashed") \(results.count) file\(results.count == 1 ? "" : "s")"
                 : "\(results.count - failed.count) done, \(failed.count) failed")
                .font(.headline)
            if !failed.isEmpty {
                List(failed) { f in
                    VStack(alignment: .leading) {
                        Text(f.filename)
                        Text(f.error ?? "").font(.caption).foregroundStyle(.red)
                    }
                }
                .frame(minHeight: 100, maxHeight: 220)
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
    }

    private func run() {
        phase = .working
        let targets = eligible
        Task {
            let op = FileOperator(database: env.database, bookmarks: env.bookmarks)
            results = await op.perform(permanent ? .deletePermanently : .trash, on: targets)
            phase = .done
            for id in Set(targets.map(\.rootId)) { await env.scanner.scan(rootId: id) }
        }
    }
}
