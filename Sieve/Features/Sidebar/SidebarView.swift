import SwiftUI

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
                    HStack {
                        Label(tag.name, systemImage: "tag")
                        Spacer()
                        Text("\(tag.count)").foregroundStyle(.secondary).font(.caption)
                    }
                    .tag(LibraryScope.tag(tag.id))
                    .contextMenu {
                        Button("Delete Tag", role: .destructive) {
                            Task { try? await AnnotationStore(database: env.database).deleteTag(id: tag.id) }
                        }
                    }
                    .dropDestination(for: Int64.self) { ids, _ in
                        let rows = model.rows.filter { ids.contains($0.id) }
                        Task { try? await AnnotationStore(database: env.database).addTag(named: tag.name, to: rows) }
                        return true
                    }
                }
                if model.tags.isEmpty {
                    Text("Add tags from the inspector").font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Quick Tags") {
                let slots = QuickTags.load(quickTagSlotsJSON)
                ForEach(0..<QuickTags.count, id: \.self) { i in
                    HStack {
                        QuickTagLabel(slots: slots, index: i)
                        Spacer()
                        Text("\(model.quickTagCounts[i])").foregroundStyle(.secondary).font(.caption)
                    }
                    .tag(LibraryScope.quickTag(i))
                    .dropDestination(for: Int64.self) { ids, _ in
                        let rows = model.rows.filter { ids.contains($0.id) }
                        Task { try? await AnnotationStore(database: env.database).addQuickTag(i, to: rows) }
                        return true
                    }
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
                    Label(node.name, systemImage: "folder")
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

    @ViewBuilder
    private func rootLabel(_ root: Root, id: Int64) -> some View {
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
