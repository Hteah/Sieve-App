import Testing
@testable import Sieve

struct AppThemeTests {
    @Test func customPaletteHexRoundTrips() {
        for hex in ["#101820", "#F5B854", "#FFFFFF", "#000000"] {
            #expect(CustomPalette.hex(CustomPalette.color(hex)!) == hex)
        }
        #expect(CustomPalette.color("nope") == nil)
        #expect(CustomPalette.color("12345") == nil)
    }

    @Test func customPaletteSchemeFollowsSurfaceLuminance() {
        let dark = CustomPalette.palette(surface: "#222222", chrome: "#111111", divider: "#000000", accent: "#F5B854")
        let light = CustomPalette.palette(surface: "#DDDDDD", chrome: "#CCCCCC", divider: "#AAAAAA", accent: "#333333")
        #expect(dark.scheme == .dark)
        #expect(light.scheme == .light)
    }

    @Test func everyStartFromPresetParses() {
        for p in CustomPalette.presets {
            #expect(CustomPalette.color(p.surface) != nil)
            #expect(CustomPalette.color(p.chrome) != nil)
            #expect(CustomPalette.color(p.divider) != nil)
            #expect(CustomPalette.color(p.accent) != nil)
        }
    }

    @Test func defaultPaletteIsUsable() {
        let p = CustomPalette.defaultPalette
        #expect(p.scheme == .dark)
        #expect(p.accent == CustomPalette.color("#F5B854"))
    }
}
