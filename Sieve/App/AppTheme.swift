import SwiftUI

/// User-selectable accent colour. `.system` = follow the macOS accent (no tint override).
enum AppTheme: String, CaseIterable, Identifiable {
    case system, blue, indigo, purple, pink, red, orange, green, teal, graphite

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "System"
        case .blue: "Blue"
        case .indigo: "Indigo"
        case .purple: "Purple"
        case .pink: "Pink"
        case .red: "Red"
        case .orange: "Orange"
        case .green: "Green"
        case .teal: "Teal"
        case .graphite: "Graphite"
        }
    }

    /// Tint colour, or `nil` to leave the system accent alone.
    var accent: Color? {
        switch self {
        case .system: nil
        case .blue: .blue
        case .indigo: .indigo
        case .purple: .purple
        case .pink: .pink
        case .red: .red
        case .orange: .orange
        case .green: .green
        case .teal: .teal
        case .graphite: Color(white: 0.55)
        }
    }

    /// Colour to draw waveforms with (falls back to the live accent for `.system`).
    var waveformColor: Color { accent ?? .accentColor }

    static func current(_ raw: String) -> AppTheme { AppTheme(rawValue: raw) ?? .system }
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// Applies the stored accent theme + appearance to a scene's root view.
struct Themed: ViewModifier {
    @AppStorage("appTheme") private var themeRaw = AppTheme.system.rawValue
    @AppStorage("appAppearance") private var appearanceRaw = AppAppearance.system.rawValue

    func body(content: Content) -> some View {
        let theme = AppTheme.current(themeRaw)
        let appearance = AppAppearance(rawValue: appearanceRaw) ?? .system
        content
            .tint(theme.accent)   // nil = no override
            .preferredColorScheme(appearance.colorScheme)
    }
}
