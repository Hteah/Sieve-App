import Foundation
import Testing
@testable import Sieve

struct AppThemeTests {
    @Test func sharedTextRoundTrips() {
        var p = ThemePalette()
        p["windowBg"] = 0xff8797ac
        p["gridLine"] = 0x80000000
        p.shadedPanel = true
        p.edgeShadeAlpha = 0.3
        #expect(ThemePalette(string: p.string) == p)
        #expect(ThemePalette(string: p.string).string == p.string)
    }

    /// R3WRK's own text (as its `Palette::toString()` writes it, floats to 3 places) parses.
    @Test func parsesR3WRKText() {
        let madrona = ThemePalette.builtIn("Madrona")!
        #expect(madrona["windowBg"] == 0xff8797ac)
        #expect(madrona["textDim"] == 0xff46536a)
        #expect(madrona["popupBg"] == 0xffada56a)   // missing key keeps Midnight's
        let r3wrk = ThemePalette(string: "windowBg:ffc9cbce;shadedPanel:1;edgeShadeDarken:0.850;edgeShadeAlpha:0.420")
        #expect(r3wrk == ThemePalette.builtIn("Silver").map { var s = ThemePalette(); s["windowBg"] = $0["windowBg"]; s.shadedPanel = true; return s })
    }

    @Test func unknownKeysAreIgnored() {
        let p = ThemePalette(string: "futureKey:ff00ff00;accent:ff112233;junk")
        #expect(p["accent"] == 0xff112233)
        #expect(ThemePalette(string: "futureKey:ff00ff00") == ThemePalette.midnight)
    }

    @Test func clipboardTextRoundTrips() {
        let p = ThemePalette.builtIn("Amber")!
        let parsed = ThemePalette.fromClipboardText(p.clipboardText(name: "Grey Blue"))
        #expect(parsed?.palette == p)
        #expect(parsed?.name == "Grey Blue")
        #expect(ThemePalette.fromClipboardText(p.string)?.palette == p)   // bare text pastes too
        #expect(ThemePalette.fromClipboardText("hello there") == nil)
    }

    @Test func hexParsing() {
        #expect(ThemePalette.parseARGB("#F5B854") == 0xfff5b854)
        #expect(ThemePalette.parseARGB("80000000") == 0x80000000)
        #expect(ThemePalette.parseARGB("12345") == nil)
        #expect(ThemePalette.hexString(0xfff5b854) == "F5B854")
        #expect(ThemePalette.hexString(0x29ffffff) == "29FFFFFF")
        for v: UInt32 in [0xff101820, 0xfff5b854, 0x80000000] {
            #expect(ThemePalette.argb(ThemePalette.color(v)) == v)
        }
    }

    @Test func everyBuiltInParsesWithADistinctName() {
        #expect(Set(ThemePalette.builtIns.map(\.name)).count == ThemePalette.builtIns.count)
        for b in ThemePalette.builtIns {
            #expect(ThemePalette.fromClipboardText(b.spec) != nil, "\(b.name)")
        }
    }

    /// The old four Sieve colours map onto the shared fields, and Sieve's old presets (now
    /// built-ins) are exactly what that mapping gives.
    @Test func legacyColoursConvert() {
        let p = ThemePalette.fromLegacy(surface: "#37474F", chrome: "#293238", divider: "#2C3A42", accent: "#F5B854")
        #expect(p == ThemePalette.builtIn("Ableton Dark Blue-Grey"))
        #expect(Palette(theme: p).scheme == .dark)
        let light = ThemePalette.fromLegacy(surface: "#DDDDDD", chrome: "#CCCCCC", divider: "#AAAAAA", accent: "#333333")
        #expect(Palette(theme: light).scheme == .light)
        #expect(light["screenText"] == 0xff1f242b)
    }

    @Test func migrationKeepsTheUsersColours() {
        let d = UserDefaults(suiteName: "AppThemeTests.\(UUID())")!
        d.set("#434343", forKey: "customSurfaceHex")
        d.set("#2E2E2E", forKey: "customChromeHex")
        d.set("#363636", forKey: "customDividerHex")
        d.set("#F5B854", forKey: "customAccentHex")
        ThemeLibrary.migrateLegacySettings(d)
        #expect(ThemePalette(string: d.string(forKey: ThemeLibrary.activeKey)!) == ThemePalette.builtIn("Charcoal"))
        d.set("accent:ff000000", forKey: ThemeLibrary.activeKey)
        ThemeLibrary.migrateLegacySettings(d)   // runs once only
        #expect(d.string(forKey: ThemeLibrary.activeKey) == "accent:ff000000")
    }

    @Test func libraryFilesRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "themes-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let p = ThemePalette.builtIn("Paper")!
        #expect(ThemeLibrary.save(p, as: "A/B", in: dir))
        #expect(ThemeLibrary.names(in: dir) == ["A-B"])
        #expect(ThemeLibrary.load("A-B", in: dir) == p)
        ThemeLibrary.delete("A-B", in: dir)
        #expect(ThemeLibrary.names(in: dir).isEmpty)
    }
}
