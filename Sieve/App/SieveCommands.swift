import SwiftUI

struct SieveCommands: Commands {
    let env: AppEnvironment
    @Environment(\.openWindow) private var openWindow
    @AppStorage("showControlInfo") private var showControlInfo = false

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Add Folder…") { Task { await env.addRootViaPanel() } }
                .keyboardShortcut("o", modifiers: [.command])
            Button("Rescan All") { Task { await env.scanner.scanAll() } }
                .keyboardShortcut("r", modifiers: [.command])
            Divider()
            // Opens the pop-out editor on the list's current selection — the editor tracks it
            // via `noteListSelection`, so no row needs to be passed here.
            Button("Open in Wave Editor") { openWindow(id: "audio-editor") }
                .keyboardShortcut("e", modifiers: [.command])
            Button("Purge Missing Samples") { Task { await env.scanner.purgeMissing() } }
        }
        CommandGroup(after: .sidebar) {
            Toggle("Show Control Info", isOn: $showControlInfo)
        }
    }
}
