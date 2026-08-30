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
            AudioEditorView(isPopOut: true)
                .environment(env)
                .frame(minWidth: 600, minHeight: 380)
        }
        .defaultSize(width: 1040, height: 560)
        .windowLevel(.floating)   // keep the editor above other windows, including other apps

        Settings {
            SettingsView()
                .environment(env)
        }
    }
}
