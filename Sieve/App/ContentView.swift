import SwiftUI

struct ContentView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.openWindow) private var openWindow
    @State private var model: LibraryViewModel?
    // Source of truth is @State: an @AppStorage binding handed to `.inspector`
    // lags a frame, so the first toggle click can read back stale. Persisted on change.
    @State private var showInspector = UserDefaults.standard.object(forKey: "showInspector") as? Bool ?? true
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var followTask: Task<Void, Never>?

    private var sidebarShown: Bool { columnVisibility != .detailOnly }

    var body: some View {
        Group {
            if let model {
                splitView(model)
                    .navigationSplitViewStyle(.balanced)
                    .toolbar {
                        ToolbarItemGroup(placement: .primaryAction) {
                            Button { Task { await env.addRootViaPanel() } } label: { Label("Add Folder", systemImage: "folder.badge.plus") }
                                .infoBubble("Add a folder of samples")
                            Button { Task { await env.scanner.scanAll() } } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                                .infoBubble("Rescan all folders")
                                .disabled(env.scanState.isScanning)
                        }
                    }
                    .onChange(of: model.primarySelection?.id) { _, _ in
                        followTask?.cancel()
                        env.editor.noteListSelection(model.primarySelection)
                        // Follow the list selection only when the editor has nothing unsaved —
                        // a dirty editor keeps its file so browsing the list isn't blocked.
                        guard env.editor.isActive, !env.editor.isDirty,
                              let row = model.primarySelection,
                              row.id != env.editor.source?.sampleId else { return }
                        followTask = Task {
                            // Debounce for inline browsing; load immediately when the pop-out window is open.
                            if !env.editor.windowOpen {
                                try? await Task.sleep(for: .milliseconds(250))
                                guard !Task.isCancelled, model.primarySelection?.id == row.id else { return }
                            }
                            guard !Task.isCancelled else { return }
                            await env.editor.open(row: row)
                        }
                    }
            } else {
                ProgressView()
            }
        }
        .onAppear { if model == nil { model = LibraryViewModel(database: env.database) } }
        .onChange(of: showInspector) { _, shown in
            UserDefaults.standard.set(shown, forKey: "showInspector")
        }
        .alert("Something went wrong", isPresented: Binding(get: { env.lastError != nil }, set: { if !$0 { env.lastError = nil } })) {
            Button("OK") { env.lastError = nil }
        } message: {
            Text(env.lastError ?? "")
        }
    }

    /// Sidebar + list in a two-column split view; the info pane rides alongside as a
    /// native `.inspector`, so showing/hiding it slides one pane instead of rebuilding
    /// the whole split view. Fixed width, so it never grows with the window.
    private func splitView(_ model: LibraryViewModel) -> some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar(model)
        } detail: {
            centerPane(model)
                .inspector(isPresented: $showInspector) {
                    InspectorView(model: model)
                        .inspectorColumnWidth(235)
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
            .infoBubble(sidebarShown ? "Hide sidebar" : "Show sidebar", align: .leading)
            .keyboardShortcut("s", modifiers: [.control, .command])

            Spacer(minLength: 0)

            Button {
                env.editor.noteListSelection(model?.primarySelection)
                openWindow(id: "audio-editor")
            } label: {
                Image(systemName: "waveform")
            }
            .infoBubble("Open the wave editor window")
            .padding(.trailing, 12)

            Button { toggleInspector() } label: {
                Image(systemName: showInspector ? "sidebar.trailing" : "sidebar.right")
                    .foregroundStyle(showInspector ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            }
            .infoBubble(showInspector ? "Hide inspector" : "Show inspector", align: .trailing)
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
            columnVisibility = (columnVisibility == .detailOnly) ? .all : .detailOnly
        }
    }

    private func toggleInspector() {
        withAnimation(.snappy(duration: 0.2)) { showInspector.toggle() }
    }
}
