import SwiftUI

struct SieveCommands: Commands {
    let env: AppEnvironment
    @AppStorage("showControlInfo") private var showControlInfo = false

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Add Folder…") { Task { await env.addRootViaPanel() } }
                .keyboardShortcut("o", modifiers: [.command])
            Button("Rescan All") { Task { await env.scanner.scanAll() } }
                .keyboardShortcut("r", modifiers: [.command])
            Divider()
            Button("Purge Missing Samples") { Task { await env.scanner.purgeMissing() } }
        }
        CommandGroup(after: .sidebar) {
            Toggle("Show Control Info", isOn: $showControlInfo)
        }
    }
}
