import SwiftUI

struct SidebarView: View {
    @Environment(AppEnvironment.self) private var env
    @Bindable var model: LibraryViewModel
    @State private var rootToRemove: Root?

    var body: some View {
        List(selection: scopeBinding) {
            Section("Library") {
                Label("All Samples", systemImage: "waveform").tag(LibraryScope.all)
                Label("Favorites", systemImage: "heart").tag(LibraryScope.favorites)
                Label("Duplicates", systemImage: "doc.on.doc").tag(LibraryScope.duplicates)
                Label("Missing", systemImage: "questionmark.folder").tag(LibraryScope.missing)
            }
            Section("Folders") {
                ForEach(model.roots) { root in
                    if let id = root.id {
                        DisclosureGroup {
                            OutlineGroup(model.folderTrees[id] ?? [], children: \.childrenOrNil) { node in
                                Label(node.name, systemImage: "folder")
                                    .tag(LibraryScope.folder(rootId: node.rootId, parentDir: node.path))
                            }
                        } label: {
                            rootLabel(root, id: id)
                                .tag(LibraryScope.root(id))
                        }
                    }
                }
                Button { Task { await env.addRootViaPanel() } } label: {
                    Label("Add Folder…", systemImage: "plus")
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
        }
        .listStyle(.sidebar)
        .confirmationDialog("Remove \"\(rootToRemove?.name ?? "")\" from the library?", isPresented: Binding(get: { rootToRemove != nil }, set: { if !$0 { rootToRemove = nil } })) {
            Button("Remove", role: .destructive) {
                if let id = rootToRemove?.id { Task { try? await env.scanner.removeRoot(id: id) } }
                rootToRemove = nil
            }
        } message: {
            Text("Files on disk are not touched. Tags and ratings keyed by content are kept.")
        }
    }

    private var scopeBinding: Binding<LibraryScope?> {
        Binding(get: { model.filter.scope }, set: { if let s = $0 { model.filter.scope = s } })
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
            Divider()
            Button("Remove from Library…", role: .destructive) { rootToRemove = root }
        }
    }
}

extension Queries.FolderNode {
    var childrenOrNil: [Queries.FolderNode]? { children.isEmpty ? nil : children }
}
