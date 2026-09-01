import SwiftUI

/// User-selectable accent colour. `.system` = follow the macOS accent (no tint override).
enum AppTheme: String, CaseIterable, Identifiable {
    // Standard
    case system, blue, indigo, purple, pink, red, orange, green, teal, grey, graphite, industrial
    // Vintage computing
    case amber, phosphor, cgaCyan, cgaMagenta, commodore, gameBoy, plasma, dosBeige, vaporPink

    var id: String { rawValue }

    var isVintage: Bool {
        switch self {
        case .amber, .phosphor, .cgaCyan, .cgaMagenta, .commodore, .gameBoy, .plasma, .dosBeige, .vaporPink:
            true
        default:
            false
        }
    }

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
        case .grey: "Grey"
        case .graphite: "Graphite"
        case .industrial: "Industrial Grey"
        case .amber: "Amber CRT"
        case .phosphor: "Phosphor Green"
        case .cgaCyan: "CGA Cyan"
        case .cgaMagenta: "CGA Magenta"
        case .commodore: "Commodore Blue"
        case .gameBoy: "Game Boy"
        case .plasma: "Plasma Orange"
        case .dosBeige: "DOS Beige"
        case .vaporPink: "Vapor Pink"
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
        case .grey: Color(white: 0.62)          // neutral mid grey
        case .graphite: Color(white: 0.55)
        case .industrial: Self.rgb(90, 96, 104)   // cool gunmetal
        case .amber: Self.rgb(255, 176, 0)
        case .phosphor: Self.rgb(45, 255, 90)
        case .cgaCyan: Self.rgb(85, 255, 255)
        case .cgaMagenta: Self.rgb(255, 85, 255)
        case .commodore: Self.rgb(124, 124, 255)
        case .gameBoy: Self.rgb(139, 172, 15)
        case .plasma: Self.rgb(255, 106, 0)
        case .dosBeige: Self.rgb(194, 178, 128)
        case .vaporPink: Self.rgb(255, 110, 199)
        }
    }

    /// Colour to draw waveforms with (falls back to the live accent for `.system`).
    var waveformColor: Color { accent ?? .accentColor }

    static func current(_ raw: String) -> AppTheme { AppTheme(rawValue: raw) ?? .system }

    private static func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color {
        Color(.sRGB, red: r / 255, green: g / 255, blue: b / 255, opacity: 1)
    }
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark, grey, industrial

    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        case .grey: "Grey"
        case .industrial: "Industrial Grey"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark, .grey, .industrial: .dark
        }
    }

    /// A screen-wide colour wash layered over the base scheme (nil = none).
    var wash: (color: Color, opacity: Double)? {
        switch self {
        case .grey: (Color(.sRGB, red: 0.44, green: 0.47, blue: 0.52, opacity: 1), 0.28)   // cool mid grey lift
        case .industrial: (Color(.sRGB, red: 0.36, green: 0.38, blue: 0.42, opacity: 1), 0.22)
        default: nil
        }
    }
}

/// Applies the stored accent theme, appearance, and screen-dim level to a scene's root view.
struct Themed: ViewModifier {
    @AppStorage("appTheme") private var themeRaw = AppTheme.system.rawValue
    @AppStorage("appAppearance") private var appearanceRaw = AppAppearance.system.rawValue
    @AppStorage("appBrightness") private var brightness = 0.0   // -1 (dim) … +1 (bright)

    func body(content: Content) -> some View {
        let theme = AppTheme.current(themeRaw)
        let appearance = AppAppearance(rawValue: appearanceRaw) ?? .system
        content
            .tint(theme.accent)   // nil = no override
            .preferredColorScheme(appearance.colorScheme)
            // Washes are overlays, not `.brightness()` filters — a filter on the whole window
            // breaks the NavigationSplitView + toolbar safe-area layout.
            .overlay {
                if let wash = appearance.wash {
                    Rectangle()
                        .fill(wash.color)
                        .opacity(wash.opacity)
                        .blendMode(.plusLighter)
                        .allowsHitTesting(false)
                        .ignoresSafeArea()
                }
            }
            .overlay {
                if brightness != 0 {
                    Rectangle()
                        .fill(brightness < 0 ? Color.black : Color.white)
                        .opacity(brightness < 0 ? min(0.6, -brightness * 0.55) : min(0.22, brightness * 0.22))
                        .blendMode(brightness < 0 ? .normal : .plusLighter)
                        .allowsHitTesting(false)
                        .ignoresSafeArea()
                }
            }
    }
}
