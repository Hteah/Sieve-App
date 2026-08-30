import SwiftUI

@main
struct SieveApp: App {
    @State private var env = AppEnvironment.live()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(env)
                .frame(minWidth: 840, minHeight: 600)
        }
        .commands {
            SieveCommands(env: env)
        }

        Window("Audio Editor", id: "audio-editor") {
            AudioEditorView(currentRow: nil, showsPopOutButton: false)
                .environment(env)
                .frame(minWidth: 600, minHeight: 380)
        }
        .defaultSize(width: 1040, height: 560)

        Settings {
            SettingsView()
                .environment(env)
        }
    }
}
