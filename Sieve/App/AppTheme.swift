import AppKit
import SwiftUI

// MARK: - Palette

/// The colours the views paint with, resolved from the active shared theme (`ThemePalette`,
/// the format R3WRK uses too) and injected into the environment by `Themed`. `scheme`
/// (light/dark controls) follows `surface`'s luminance.
struct Palette: Equatable {
    var surface: Color    // list / sidebar / inspector background — R3WRK's panelBg
    var chrome: Color     // window toolbar + pane-button bar — windowBg
    var divider: Color    // hairlines — gridLine
    var accent: Color     // buttons, selection, markers
    var waveform: Color   // list + editor waveforms
    var playhead: Color
    var zeroLine: Color
    var unsaved: Color    // editor "unsaved" dot — loopMarker
    var record: Color     // editor record control — recordButton
    var text: Color       // screenText
    var textDim: Color    // screenTextDim
    var scheme: ColorScheme

    init(theme t: ThemePalette) {
        surface = t.color("panelBg"); chrome = t.color("windowBg"); divider = t.color("gridLine")
        accent = t.color("accent"); waveform = t.color("waveform"); playhead = t.color("playhead")
        zeroLine = t.color("zeroLine"); unsaved = t.color("loopMarker"); record = t.color("recordButton")
        text = t.color("screenText"); textDim = t.color("screenTextDim")
        scheme = ThemePalette.luminance(t["panelBg"]) < 0.5 ? .dark : .light
    }

    static let `default` = Palette(theme: ThemePalette.builtIn("Ableton Dark Blue-Grey")!)
}

private struct PaletteKey: EnvironmentKey {
    static let defaultValue = Palette.default
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
    @AppStorage(ThemeLibrary.activeKey) private var themeText = ""

    func body(content: Content) -> some View {
        let palette = themeText.isEmpty ? Palette.default : Palette(theme: ThemePalette(string: themeText))
        content
            .environment(\.palette, palette)
            .tint(palette.accent)
            .foregroundStyle(palette.text, palette.textDim)
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

