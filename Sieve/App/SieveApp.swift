import SwiftUI

@main
struct SieveApp: App {
    @State private var env = AppEnvironment.live()

    init() {
        // First-launch look: Amber CRT accent over Industrial Grey, a touch brighter, with
        // the inspector collapsed. `register` only fills keys the user hasn't set, so this
        // never overrides a later choice.
        UserDefaults.standard.register(defaults: [
            "appTheme": AppTheme.amber.rawValue,
            "appAppearance": AppAppearance.industrial.rawValue,
            "appBrightness": 0.47,
            "showInspector": false,
        ])
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(env)
                .frame(minWidth: 840, minHeight: 600)
                .modifier(Themed())
        }
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

        Settings {
            SettingsView()
                .environment(env)
                .modifier(Themed())
        }
    }
}
