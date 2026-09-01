import SwiftUI

struct ContentView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.openWindow) private var openWindow
    @State private var model: LibraryViewModel?
    @AppStorage("showInspector") private var showInspector = true
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var followTask: Task<Void, Never>?

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
                    // Fixed width, matched to the sidebar. A single value makes the column
                    // non-resizable, so growing the window only stretches the center list.
                    .navigationSplitViewColumnWidth(235)
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
            .infoBubble(sidebarShown ? "Hide sidebar" : "Show sidebar")
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
            .infoBubble(showInspector ? "Hide inspector" : "Show inspector")
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
