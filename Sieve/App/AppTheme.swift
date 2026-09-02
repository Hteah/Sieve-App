import AppKit
import SwiftUI

// MARK: - Palette

/// The app's colour scheme: four user-chosen colours that `Themed` injects into the environment
/// for the chrome-painting views. `scheme` (light/dark text) is derived from `surface`'s
/// luminance so text always contrasts.
struct Palette: Equatable {
    var surface: Color   // list / sidebar / inspector background (every row — stripe is turned off)
    var chrome: Color    // window toolbar + pane-button bar
    var divider: Color   // hairlines
    var accent: Color    // buttons, selection, waveform
    var scheme: ColorScheme
}

/// Reads / writes the custom-palette preferences and turns them into a `Palette`.
enum CustomPalette {
    static let surfaceKey = "customSurfaceHex"
    static let chromeKey  = "customChromeHex"
    static let dividerKey  = "customDividerHex"
    static let accentKey  = "customAccentHex"

    /// Dark-slate defaults (also the "Reset colours" target).
    static let defaults: [String: String] = [
        surfaceKey: "#37474F", chromeKey: "#293238", dividerKey: "#2C3A42", accentKey: "#F5B854",
    ]

    static func palette(surface: String, chrome: String, divider: String, accent: String) -> Palette {
        let s = color(surface) ?? color(defaults[surfaceKey]!)!
        return Palette(
            surface: s,
            chrome:  color(chrome)  ?? color(defaults[chromeKey]!)!,
            divider: color(divider) ?? color(defaults[dividerKey]!)!,
            accent:  color(accent)  ?? color(defaults[accentKey]!)!,
            scheme:  luminance(s) < 0.5 ? .dark : .light
        )
    }

    static func color(_ hex: String) -> Color? {
        let t = hex.trimmingCharacters(in: CharacterSet(charactersIn: " #")).uppercased()
        guard t.count == 6, let v = Int(t, radix: 16) else { return nil }
        return Color(.sRGB, red: Double((v >> 16) & 0xFF) / 255,
                     green: Double((v >> 8) & 0xFF) / 255,
                     blue: Double(v & 0xFF) / 255, opacity: 1)
    }

    static func hex(_ color: Color) -> String {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
        return String(format: "#%02X%02X%02X",
                      Int((ns.redComponent * 255).rounded()),
                      Int((ns.greenComponent * 255).rounded()),
                      Int((ns.blueComponent * 255).rounded()))
    }

    private static func luminance(_ color: Color) -> Double {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
        return 0.299 * ns.redComponent + 0.587 * ns.greenComponent + 0.114 * ns.blueComponent
    }

    /// Named starting points for the "Start from…" menu — (label, surface, chrome, divider, accent).
    static let presets: [(name: String, surface: String, chrome: String, divider: String, accent: String)] = [
        ("Ableton Dark Blue-Grey", "#37474F", "#293238", "#2C3A42", "#F5B854"),
        ("Charcoal",               "#434343", "#2E2E2E", "#363636", "#F5B854"),
        ("Neutral Grey",           "#616161", "#3A3A3A", "#4E4E4E", "#F5B854"),
        ("Slate Blue",             "#2E3440", "#21252E", "#262B36", "#88C0D0"),
        ("Warm Graphite",          "#3A3736", "#262322", "#302C2B", "#E0A24E"),
    ]

    static var defaultPalette: Palette {
        palette(surface: defaults[surfaceKey]!, chrome: defaults[chromeKey]!,
                divider: defaults[dividerKey]!, accent: defaults[accentKey]!)
    }
}

private struct PaletteKey: EnvironmentKey {
    static let defaultValue = CustomPalette.defaultPalette
}
extension EnvironmentValues {
    /// The app's colour palette, set by `Themed`.
    var palette: Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}

extension View {
    /// Paints `palette.surface` behind a scrollable container (List / Table / ScrollView).
    func themedSurface(_ palette: Palette) -> some View {
        scrollContentBackground(.hidden).background(palette.surface)
    }
    /// Paints `palette.chrome` behind a bar (toolbar strip, pane-button bar).
    func themedChrome(_ palette: Palette) -> some View {
        background(palette.chrome)
    }
}

/// Injects the colour palette and screen-dim level into a scene's root view.
struct Themed: ViewModifier {
    @AppStorage("appBrightness") private var brightness = 0.0   // -1 (dim) … +1 (bright)
    @AppStorage(CustomPalette.surfaceKey) private var customSurface = CustomPalette.defaults[CustomPalette.surfaceKey]!
    @AppStorage(CustomPalette.chromeKey) private var customChrome = CustomPalette.defaults[CustomPalette.chromeKey]!
    @AppStorage(CustomPalette.dividerKey) private var customDivider = CustomPalette.defaults[CustomPalette.dividerKey]!
    @AppStorage(CustomPalette.accentKey) private var customAccent = CustomPalette.defaults[CustomPalette.accentKey]!

    func body(content: Content) -> some View {
        let palette = CustomPalette.palette(surface: customSurface, chrome: customChrome,
                                            divider: customDivider, accent: customAccent)
        content
            .environment(\.palette, palette)
            .tint(palette.accent)
            .preferredColorScheme(palette.scheme)
            .background(palette.surface.ignoresSafeArea())
            // A dim/brighten overlay, not a `.brightness()` filter — a filter on the whole window
            // breaks the NavigationSplitView + toolbar safe-area layout.
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

