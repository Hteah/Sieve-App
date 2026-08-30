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
        Settings {
            SettingsView()
                .environment(env)
        }
    }
}
