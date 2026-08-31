import SwiftUI

struct ContentView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var model: LibraryViewModel?
    @AppStorage("showInspector") private var showInspector = true
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var pendingSwitch: PendingSwitch?
    @State private var followTask: Task<Void, Never>?

    private struct PendingSwitch: Identifiable {
        let id = UUID()
        let row: SampleRow
        let previousId: Int64?
    }

    private var sidebarShown: Bool {
        showInspector ? (columnVisibility == .all) : (columnVisibility != .detailOnly)
    }

    var body: some View {
        Group {
            if let model {
                splitView(model)
                    .navigationSplitViewStyle(.balanced)
                    .toolbar {
                        ToolbarItemGroup(placement: .primaryAction) {
                            Button { Task { await env.addRootViaPanel() } } label: { Label("Add Folder", systemImage: "folder.badge.plus") }
                                .help("Add a folder of samples")
                            Button { Task { await env.scanner.scanAll() } } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                                .help("Rescan all folders")
                                .disabled(env.scanState.isScanning)
                        }
                    }
                    .onChange(of: model.primarySelection?.id) { oldId, _ in
                        followTask?.cancel()
                        guard env.editor.isActive, let row = model.primarySelection,
                              row.id != env.editor.source?.sampleId else { return }
                        if env.editor.isDirty {
                            pendingSwitch = PendingSwitch(row: row, previousId: oldId)
                        } else {
                            followTask = Task {
                                // Debounce only for inline browsing; load immediately when the
                                // dedicated editor window is open.
                                if !env.editor.windowOpen {
                                    try? await Task.sleep(for: .milliseconds(250))
                                    guard !Task.isCancelled, model.primarySelection?.id == row.id else { return }
                                }
                                guard !Task.isCancelled else { return }
                                await env.editor.open(row: row)
                            }
                        }
                    }
                    .confirmationDialog(
                        "Unsaved Edits",
                        isPresented: Binding(get: { pendingSwitch != nil },
                                             set: { if !$0 { pendingSwitch = nil } }),
                        presenting: pendingSwitch
                    ) { pending in
                        Button("Save & Switch") {
                            Task {
                                await env.editor.saveReplacingOriginal(bits: env.editor.source?.sourceBits ?? .int24)
                                await env.editor.open(row: pending.row)
                            }
                        }
                        Button("Discard Edits & Switch", role: .destructive) {
                            Task { await env.editor.open(row: pending.row) }
                        }
                        Button("Cancel", role: .cancel) {
                            if let previous = pending.previousId { model.selection = [previous] }
                        }
                    } message: { _ in
                        Text("The audio editor has unsaved changes for “\(env.editor.source?.url.lastPathComponent ?? "the current file")”.")
                    }
            } else {
                ProgressView()
            }
        }
        .onAppear { if model == nil { model = LibraryViewModel(database: env.database) } }
        .alert("Something went wrong", isPresented: Binding(get: { env.lastError != nil }, set: { if !$0 { env.lastError = nil } })) {
            Button("OK") { env.lastError = nil }
        } message: {
            Text(env.lastError ?? "")
        }
    }

    /// Three real split-view columns (sidebar / list / inspector) when the inspector is shown,
    /// dropping to two when it is hidden. A true column resizes by its divider only and never
    /// grows the window.
    @ViewBuilder
    private func splitView(_ model: LibraryViewModel) -> some View {
        if showInspector {
            NavigationSplitView(columnVisibility: $columnVisibility) {
                sidebar(model)
            } content: {
                centerPane(model)
                    .navigationSplitViewColumnWidth(min: 320, ideal: 640)
            } detail: {
                InspectorView(model: model)
                    .navigationSplitViewColumnWidth(min: 260, ideal: 340, max: 560)
            }
        } else {
            NavigationSplitView(columnVisibility: $columnVisibility) {
                sidebar(model)
            } detail: {
                centerPane(model)
            }
        }
    }

    private func sidebar(_ model: LibraryViewModel) -> some View {
        SidebarView(model: model)
            .navigationSplitViewColumnWidth(min: 150, ideal: 190, max: 300)
    }

    private func centerPane(_ model: LibraryViewModel) -> some View {
        Group {
            if model.showsDuplicates {
                DuplicateGroupsView(model: model)
            } else {
                SampleListView(model: model)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { paneToggleBar }
    }

    private var paneToggleBar: some View {
        HStack(spacing: 0) {
            Button { toggleSidebar() } label: {
                Image(systemName: sidebarShown ? "sidebar.leading" : "sidebar.left")
                    .foregroundStyle(sidebarShown ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            }
            .help(sidebarShown ? "Hide sidebar" : "Show sidebar")
            .keyboardShortcut("s", modifiers: [.control, .command])

            Spacer(minLength: 0)

            Button { toggleInspector() } label: {
                Image(systemName: showInspector ? "sidebar.trailing" : "sidebar.right")
                    .foregroundStyle(showInspector ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            }
            .help(showInspector ? "Hide inspector" : "Show inspector")
            .keyboardShortcut("i", modifiers: [.control, .command])
        }
        .buttonStyle(.borderless)
        .font(.system(size: 15))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func toggleSidebar() {
        withAnimation {
            if showInspector {
                columnVisibility = (columnVisibility == .all) ? .doubleColumn : .all
            } else {
                columnVisibility = (columnVisibility == .detailOnly) ? .all : .detailOnly
            }
        }
    }

    private func toggleInspector() {
        withAnimation {
            showInspector.toggle()
            if columnVisibility == .doubleColumn { columnVisibility = .all }
        }
    }
}
