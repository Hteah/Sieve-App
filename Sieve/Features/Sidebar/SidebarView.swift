import AppKit
import GRDB
import SwiftUI

/// Fetch full `SampleRow`s by id straight from the DB — used when a drag lands in a window whose
/// filtered list doesn't contain the dragged rows (e.g. dropped from another window).
@MainActor
func fetchSampleRows(_ ids: [Int64], from database: AppDatabase) async -> [SampleRow] {
    guard !ids.isEmpty else { return [] }
    let marks = databaseQuestionMarks(count: ids.count)
    return (try? await database.reader.read { db in
        try SampleRow.fetchAll(db, sql: "SELECT * FROM sample_with_annotation WHERE id IN (\(marks))",
                               arguments: StatementArguments(ids))
    }) ?? []
}

struct SidebarView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.palette) private var palette
    @Bindable var model: LibraryViewModel
    @AppStorage(QuickTags.storageKey) private var quickTagSlotsJSON = ""
    @State private var rootToRemove: Root?
    @State private var collapsedGroups: Set<Int64> = []
    @State private var groupSheet: GroupSheet?
    @State private var groupNameDraft = ""
    @State private var quickTagRenameSlot: Int?
    @State private var quickTagIconSlot: Int?
    @State private var quickTagNameDraft = ""
    @State private var moveHere: MoveHereRequest?
    /// Folder row a sample drag is hovering, keyed `r:<id>` / `n:<rootId>:<path>`.
    @State private var dropHoverKey: String?

    private struct MoveHereRequest: Identifiable {
        let id = UUID()
        let rows: [SampleRow]
        let destination: URL
    }

    /// List rows currently selected that can actually be moved: present, on an available root.
    private var movableSelection: [SampleRow] {
        model.rows.filter { model.selection.contains($0.id) && $0.status == .present }
    }

    private func stageMoveHere(into destination: URL) {
        let rows = movableSelection
        guard !rows.isEmpty else { return }
        moveHere = MoveHereRequest(rows: rows, destination: destination)
    }

    /// Called by the AppKit drop catcher when sample ids are dropped on a folder row.
    private func acceptDrop(_ ids: [Int64], into destination: URL, sameFolder: @escaping (SampleRow) -> Bool) -> Bool {
        guard !ids.isEmpty else { return false }
        // Look the rows up in the DB (not `model.rows` — the drag may be from another window).
        Task { @MainActor in
            let rows = await fetchSampleRows(ids, from: env.database)
                .filter { $0.status == .present && !sameFolder($0) }
            guard !rows.isEmpty else { return }
            moveHere = MoveHereRequest(rows: rows, destination: destination)
        }
        return true
    }

    private enum GroupSheet: Identifiable {
        case create(assignRoot: Int64?)
        case rename(FolderGroup)
        var id: String {
            switch self {
            case .create(let r): "create-\(r.map(String.init) ?? "")"
            case .rename(let g): "rename-\(g.id ?? 0)"
            }
        }
        var isRename: Bool { if case .rename = self { true } else { false } }
    }

    private var groupStore: FolderGroupStore { FolderGroupStore(database: env.database) }

    var body: some View {
        List(selection: scopeBinding) {
            Section("Library") {
                Label("All Samples", systemImage: "waveform").tag(LibraryScope.all)
                Label("Favorites", systemImage: "heart").tag(LibraryScope.favorites)
                Label("Duplicates", systemImage: "doc.on.doc").tag(LibraryScope.duplicates)
                Label("Missing", systemImage: "questionmark.folder").tag(LibraryScope.missing)
            }

            Section("Folders") {
                ForEach(model.groups) { group in
                    if let gid = group.id {
                        DisclosureGroup(isExpanded: expansion(for: gid)) {
                            ForEach(roots(in: gid)) { root in rootRow(root) }
                        } label: {
                            groupLabel(group, id: gid).tag(LibraryScope.group(gid))
                        }
                    }
                }

                ForEach(ungroupedRoots) { root in rootRow(root) }

                Button { Task { await env.addRootViaPanel() } } label: {
                    Label("Add Folder…", systemImage: "plus")
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)

                Button {
                    groupNameDraft = ""
                    groupSheet = .create(assignRoot: nil)
                } label: {
                    Label("New Group…", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
            }

            Section("Tags") {
                ForEach(model.tags) { tag in
                    let key = "tag:\(tag.id)"
                    HStack {
                        Label(tag.name, systemImage: "tag")
                        Spacer()
                        Text("\(tag.count)").foregroundStyle(.secondary).font(.caption)
                    }
                    .padding(.vertical, 1).padding(.horizontal, 3)
                    .background { dropHighlight(key) }
                    .background {
                        tagDropCatcher(key: key) { rows in
                            Task { try? await AnnotationStore(database: env.database).addTag(named: tag.name, to: rows) }
                        }
                    }
                    .tag(LibraryScope.tag(tag.id))
                    .contextMenu {
                        Button("Delete Tag", role: .destructive) {
                            Task { try? await AnnotationStore(database: env.database).deleteTag(id: tag.id) }
                        }
                    }
                }
                if model.tags.isEmpty {
                    Text("Add tags from the inspector").font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Quick Tags") {
                let slots = QuickTags.load(quickTagSlotsJSON)
                ForEach(0..<QuickTags.count, id: \.self) { i in
                    let key = "qt:\(i)"
                    HStack {
                        QuickTagLabel(slots: slots, index: i)
                        Spacer()
                        Text("\(model.quickTagCounts[i])").foregroundStyle(.secondary).font(.caption)
                    }
                    .padding(.vertical, 1).padding(.horizontal, 3)
                    .background { dropHighlight(key) }
                    .background {
                        tagDropCatcher(key: key) { rows in
                            Task { try? await AnnotationStore(database: env.database).addQuickTag(i, to: rows) }
                        }
                    }
                    .tag(LibraryScope.quickTag(i))
                    .contextMenu {
                        Button("Rename…") {
                            quickTagNameDraft = QuickTags.displayName(slots, i)
                            quickTagRenameSlot = i
                        }
                        Button("Choose Icon…") { quickTagIconSlot = i }
                        Button("Default Icon") { updateSlot(i) { $0.symbol = QuickTags.defaults[i].symbol } }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .themedSurface(palette)
        .alert("Rename Quick Tag", isPresented: Binding(get: { quickTagRenameSlot != nil }, set: { if !$0 { quickTagRenameSlot = nil } })) {
            TextField("Name", text: $quickTagNameDraft)
            Button("Cancel", role: .cancel) { quickTagRenameSlot = nil }
            Button("Rename") {
                if let i = quickTagRenameSlot { updateSlot(i) { $0.name = quickTagNameDraft } }
                quickTagRenameSlot = nil
            }
        }
        .sheet(isPresented: Binding(get: { quickTagIconSlot != nil }, set: { if !$0 { quickTagIconSlot = nil } })) {
            if let i = quickTagIconSlot {
                let slots = QuickTags.load(quickTagSlotsJSON)
                SymbolGridPicker(title: "Icon for \(QuickTags.displayName(slots, i))",
                                 selected: QuickTags.symbolName(slots, i)) { symbol in
                    updateSlot(i) { $0.symbol = symbol }
                }
            }
        }
        .confirmationDialog("Remove \"\(rootToRemove?.name ?? "")\" from the library?", isPresented: Binding(get: { rootToRemove != nil }, set: { if !$0 { rootToRemove = nil } })) {
            Button("Remove", role: .destructive) {
                if let id = rootToRemove?.id { Task { try? await env.scanner.removeRoot(id: id) } }
                rootToRemove = nil
            }
        } message: {
            Text("Files on disk are not touched. Tags and ratings keyed by content are kept.")
        }
        .alert(groupSheet?.isRename == true ? "Rename Group" : "New Group",
               isPresented: Binding(get: { groupSheet != nil }, set: { if !$0 { groupSheet = nil } }),
               presenting: groupSheet) { sheet in
            TextField("Name", text: $groupNameDraft)
            Button("Cancel", role: .cancel) { groupSheet = nil }
            Button(sheet.isRename ? "Rename" : "Create") { commitGroupSheet(sheet) }
        }
        .sheet(item: $moveHere) { req in
            MoveToFolderSheet(model: model, rows: req.rows, destination: req.destination)
        }
    }

    // MARK: Rows

    @ViewBuilder
    private func rootRow(_ root: Root) -> some View {
        if let id = root.id {
            DisclosureGroup {
                OutlineGroup(model.folderTrees[id] ?? [], children: \.childrenOrNil) { node in
                    let key = "n:\(node.rootId):\(node.path)"
                    Label(node.name, systemImage: "folder")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 1).padding(.horizontal, 3)
                        .background { dropHighlight(key) }
                        .background { folderDropCatcher(key: key, rootId: node.rootId, subpath: node.path) }
                        .tag(LibraryScope.folder(rootId: node.rootId, parentDir: node.path))
                        .contextMenu {
                            Button("Move Selected Samples Here") {
                                if let root = env.rootURL(for: node.rootId) {
                                    stageMoveHere(into: root.appending(path: node.path))
                                }
                            }
                            .disabled(movableSelection.isEmpty)
                        }
                }
            } label: {
                rootLabel(root, id: id)
                    .tag(LibraryScope.root(id))
            }
        }
    }

    private func folderDropCatcher(key: String, rootId: Int64, subpath: String) -> some View {
        SampleDropCatcher(
            onTargeted: { over in
                if over { dropHoverKey = key } else if dropHoverKey == key { dropHoverKey = nil }
            },
            onDrop: { ids in
                guard let root = env.rootURL(for: rootId) else { return false }
                let dest = subpath.isEmpty ? root : root.appending(path: subpath)
                return acceptDrop(ids, into: dest) { $0.rootId == rootId && $0.parentDir == subpath }
            }
        )
    }

    /// The tag / Quick Tag equivalent: drop the dragged rows onto a sidebar tag to apply it.
    private func tagDropCatcher(key: String, apply: @escaping ([SampleRow]) -> Void) -> some View {
        SampleDropCatcher(
            onTargeted: { over in
                if over { dropHoverKey = key } else if dropHoverKey == key { dropHoverKey = nil }
            },
            onDrop: { ids in
                guard !ids.isEmpty else { return false }
                Task { @MainActor in
                    let rows = await fetchSampleRows(ids, from: env.database)
                    guard !rows.isEmpty else { return }
                    apply(rows)
                }
                return true
            }
        )
    }

    /// The accent-tinted background shown while a sample drag hovers a droppable row.
    private func dropHighlight(_ key: String) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(dropHoverKey == key ? Color.accentColor.opacity(0.28) : .clear)
    }

    @ViewBuilder
    private func rootLabel(_ root: Root, id: Int64) -> some View {
        let key = "r:\(id)"
        HStack(spacing: 6) {
            Circle().fill(root.isAvailable ? Color.green : Color.orange).frame(width: 7, height: 7)
                .help(root.isAvailable ? "Available" : "Volume not mounted")
            Label(root.name, systemImage: "externaldrive")
            Spacer()
            if env.scanState.activeRoots[id] != nil {
                ProgressView().controlSize(.mini)
            } else {
                Text("\(root.fileCount)").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 1).padding(.horizontal, 3)
        .background { dropHighlight(key) }
        .background { folderDropCatcher(key: key, rootId: id, subpath: "") }
        .contextMenu {
            Button("Rescan") { Task { await env.scanner.scan(rootId: id) } }
            Button("Reveal in Finder") {
                if let url = env.rootURL(for: id) { withSecurityScope(url) { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
            }
            Button("Relink…") { Task { await env.relinkRootViaPanel(rootId: id) } }
            Button("Move Selected Samples Here") {
                if let url = env.rootURL(for: id) { stageMoveHere(into: url) }
            }
            .disabled(movableSelection.isEmpty)
            Divider()
            Menu("Move to Group") {
                ForEach(model.groups) { group in
                    if let gid = group.id {
                        Button(group.name) { Task { try? await groupStore.assign(rootId: id, to: gid) } }
                            .disabled(root.groupId == gid)
                    }
                }
                if !model.groups.isEmpty { Divider() }
                Button("None") { Task { try? await groupStore.assign(rootId: id, to: nil) } }
                    .disabled(root.groupId == nil)
                Button("New Group…") {
                    groupNameDraft = ""
                    groupSheet = .create(assignRoot: id)
                }
            }
            Divider()
            Button("Remove from Library…", role: .destructive) { rootToRemove = root }
        }
    }

    private func groupLabel(_ group: FolderGroup, id: Int64) -> some View {
        let count = roots(in: id).reduce(0) { $0 + $1.fileCount }
        return HStack(spacing: 6) {
            Label(group.name, systemImage: "folder.fill")
            Spacer()
            Text("\(count)").font(.caption).foregroundStyle(.secondary)
        }
        .contextMenu {
            Button("Rename…") {
                groupNameDraft = group.name
                groupSheet = .rename(group)
            }
            Button("Delete Group", role: .destructive) {
                Task { try? await groupStore.delete(id: id) }
            }
        }
    }

    // MARK: Helpers

    private var scopeBinding: Binding<LibraryScope?> {
        Binding(get: { model.filter.scope }, set: { if let s = $0 { model.filter.scope = s } })
    }

    private func roots(in groupId: Int64) -> [Root] {
        model.roots.filter { $0.groupId == groupId }
    }

    private var ungroupedRoots: [Root] {
        model.roots.filter { $0.groupId == nil }
    }

    private func expansion(for groupId: Int64) -> Binding<Bool> {
        Binding(get: { !collapsedGroups.contains(groupId) },
                set: { open in
                    if open { collapsedGroups.remove(groupId) } else { collapsedGroups.insert(groupId) }
                })
    }

    /// Load the 6 Quick Tag slots, mutate slot `i`, and persist back to `@AppStorage`.
    private func updateSlot(_ i: Int, _ transform: (inout QuickTag) -> Void) {
        var slots = QuickTags.load(quickTagSlotsJSON)
        guard slots.indices.contains(i) else { return }
        transform(&slots[i])
        quickTagSlotsJSON = QuickTags.encode(slots)
    }

    private func commitGroupSheet(_ sheet: GroupSheet) {
        let name = groupNameDraft
        groupSheet = nil
        switch sheet {
        case .create(let assignRoot):
            Task {
                guard let gid = try? await groupStore.create(name: name) else { return }
                if let rootId = assignRoot { try? await groupStore.assign(rootId: rootId, to: gid) }
            }
        case .rename(let group):
            guard let id = group.id else { return }
            Task { try? await groupStore.rename(id: id, to: name) }
        }
    }
}

extension Queries.FolderNode {
    var childrenOrNil: [Queries.FolderNode]? { children.isEmpty ? nil : children }
}

/// AppKit drop target for a sample-row drag, placed as a `.background` behind a sidebar folder /
/// tag row or the list pane. SwiftUI's own `.dropDestination` on `List` rows takes the hover but
/// hands the drop an empty payload, and doesn't see drags from another window at all; reading
/// `NSPasteboard` directly works for both. The dragged rows carry their id as plain text
/// (`SampleDrag`); the drop handler resolves ids against the DB, since a cross-window drop lands
/// in a window whose filtered list may not contain them.
struct SampleDropCatcher: NSViewRepresentable {
    var onTargeted: (Bool) -> Void
    /// Return true to accept; ids are the dragged sample-row ids.
    var onDrop: ([Int64]) -> Bool

    func makeNSView(context: Context) -> CatcherView {
        let v = CatcherView()
        v.onTargeted = onTargeted
        v.onDrop = onDrop
        return v
    }

    func updateNSView(_ nsView: CatcherView, context: Context) {
        nsView.onTargeted = onTargeted
        nsView.onDrop = onDrop
    }

    final class CatcherView: NSView {
        var onTargeted: ((Bool) -> Void)?
        var onDrop: (([Int64]) -> Bool)?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            registerForDraggedTypes([.string])
        }
        required init?(coder: NSCoder) { fatalError("not from a nib") }

        // Sits *behind* the row content (`.background`), so clicks land on the SwiftUI row and this
        // view only ever sees drags. It must stay hit-testable — a `hitTest`→nil override here hides
        // it from AppKit's drag routing for drags that started in another window.
        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            let ok = !Self.ids(from: sender).isEmpty
            onTargeted?(ok)
            return ok ? .copy : []
        }
        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            Self.ids(from: sender).isEmpty ? [] : .copy
        }
        override func draggingExited(_ sender: NSDraggingInfo?) { onTargeted?(false) }
        override func draggingEnded(_ sender: NSDraggingInfo) { onTargeted?(false) }
        override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
            !Self.ids(from: sender).isEmpty
        }
        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            onTargeted?(false)
            return onDrop?(Self.ids(from: sender)) ?? false
        }

        private static func ids(from sender: NSDraggingInfo) -> [Int64] {
            let pb = sender.draggingPasteboard
            if let items = pb.pasteboardItems, !items.isEmpty {
                let parsed = items.compactMap { $0.string(forType: .string).flatMap { Int64($0) } }
                if !parsed.isEmpty { return parsed }
            }
            if let s = pb.string(forType: .string), let one = Int64(s) { return [one] }
            return []
        }
    }
}
