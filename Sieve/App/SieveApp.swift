import SwiftUI

@main
struct SieveApp: App {
    @State private var env = AppEnvironment.live()

    init() {
        // First-launch: a touch brighter, inspector collapsed. The colour palette has its own
        // defaults (see `CustomPalette.defaults`). `register` only fills keys the user hasn't set.
        UserDefaults.standard.register(defaults: [
            "appBrightness": 0.47,
            "showInspector": false,
        ])
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(env)
                // Low floor so two windows fit side by side on a laptop (⌘N for a second window,
                // sharing the one library). Hide the sidebar / inspector to go narrower still.
                .frame(minWidth: 560, minHeight: 560)
                .modifier(Themed())
        }
        .defaultSize(width: 940, height: 660)
        .commands {
            SieveCommands(env: env)
        }

        Window("Audio Editor", id: "audio-editor") {
            AudioEditorView(isPopOut: true)
                .environment(env)
                .frame(minWidth: 600, minHeight: 380)
                .modifier(Themed())
        }
        .defaultSize(width: 1040, height: 560)

        Window("Move History", id: "move-history") {
            MoveHistoryView()
                .environment(env)
                .modifier(Themed())
        }
        .defaultSize(width: 900, height: 480)

        Settings {
            SettingsView()
                .environment(env)
                .modifier(Themed())
        }
    }
}
