import AppKit
import SwiftUI

// MARK: - ThemePalette

/// A full theme in the text format R3WRK uses (its `Palette::toString()`):
/// `windowBg:ff14161a;panelBg:ff17191e;…;shadedPanel:1;edgeShadeDarken:0.850;…` — colours as
/// `aarrggbb`, unknown keys ignored, missing keys keep the Midnight default. Sieve and R3WRK both
/// read and write it, so a theme moves between the apps losslessly: Sieve paints the colours it
/// has a use for and carries the rest (popup colours, shaded panel) along untouched.
struct ThemePalette: Equatable, Sendable {
    struct Field: Sendable {
        let key: String
        let label: String
        /// What the colour paints in Sieve, or nil when only R3WRK uses it.
        let sieveRole: String?
        let midnight: UInt32
    }

    /// Same keys, order and Midnight defaults as R3WRK's `kPaletteFields` (Theme.cpp).
    static let fields: [Field] = [
        Field(key: "windowBg",      label: "window background", sieveRole: "bars (toolbar, pane buttons)", midnight: 0xff14161a),
        Field(key: "panelBg",       label: "panel background",  sieveRole: "list, sidebar, inspector",     midnight: 0xff17191e),
        Field(key: "popupBg",       label: "popup background",  sieveRole: nil,                            midnight: 0xffada56a),
        Field(key: "popupInk",      label: "popup ink",         sieveRole: nil,                            midnight: 0xff3f3416),
        Field(key: "waveform",      label: "waveform",          sieveRole: "list + editor waveforms",      midnight: 0xff5ec2ff),
        Field(key: "accent",        label: "accent",            sieveRole: "selection, buttons, markers",  midnight: 0xff5ec2ff),
        Field(key: "zeroLine",      label: "zero line",         sieveRole: "editor zero line",             midnight: 0x29ffffff),
        Field(key: "gridLine",      label: "grid / lane lines", sieveRole: "dividers",                     midnight: 0x80000000),
        Field(key: "playhead",      label: "playhead",          sieveRole: "editor playhead",              midnight: 0xffff3b30),
        Field(key: "loopMarker",    label: "loop / unsaved",    sieveRole: "editor \"unsaved\" dot",       midnight: 0xffffa500),
        Field(key: "recordButton",  label: "record button",     sieveRole: "editor record control",        midnight: 0xff8b0000),
        Field(key: "text",          label: "text",              sieveRole: nil,                            midnight: 0xffe0e0e0),
        Field(key: "textDim",       label: "dim text",          sieveRole: nil,                            midnight: 0xff888888),
        Field(key: "screenText",    label: "screen text",       sieveRole: "text",                         midnight: 0xffe0e0e0),
        Field(key: "screenTextDim", label: "screen dim text",   sieveRole: "secondary text",               midnight: 0xff888888),
    ]

    /// ARGB per field key; always holds every key in `fields`.
    private(set) var argb: [String: UInt32]
    var shadedPanel = false
    var edgeShadeDarken = 0.85
    var edgeShadeAlpha = 0.42

    static let midnight = ThemePalette()

    init() {
        argb = Dictionary(uniqueKeysWithValues: Self.fields.map { ($0.key, $0.midnight) })
    }

    /// Parses the shared text. Never fails — anything unrecognised just keeps its default.
    init(string: String) {
        self.init()
        _ = apply(string)
    }

    /// Applies `key:value` tokens onto self; returns how many were recognised.
    private mutating func apply(_ string: String) -> Int {
        var known = 0
        for token in string.split(separator: ";") {
            let parts = token.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { continue }
            let (key, value) = (parts[0], parts[1])
            switch key {
            case "shadedPanel": shadedPanel = value == "1"; known += 1
            case "edgeShadeDarken": if let v = Double(value) { edgeShadeDarken = v; known += 1 }
            case "edgeShadeAlpha": if let v = Double(value) { edgeShadeAlpha = v; known += 1 }
            default:
                if argb[key] != nil, let v = Self.parseARGB(value) { argb[key] = v; known += 1 }
            }
        }
        return known
    }

    /// The shared text, same layout as R3WRK writes.
    var string: String {
        var parts = Self.fields.map { "\($0.key):\(String(format: "%08x", argb[$0.key]!))" }
        if shadedPanel { parts.append("shadedPanel:1") }
        parts.append(String(format: "edgeShadeDarken:%.3f", edgeShadeDarken))
        parts.append(String(format: "edgeShadeAlpha:%.3f", edgeShadeAlpha))
        return parts.joined(separator: ";")
    }

    subscript(key: String) -> UInt32 {
        get { argb[key] ?? 0xff000000 }
        set { if argb[key] != nil { argb[key] = newValue } }
    }

    func color(_ key: String) -> Color { Self.color(self[key]) }

    static func color(_ v: UInt32) -> Color {
        Color(.sRGB, red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255,
              blue: Double(v & 0xFF) / 255, opacity: Double(v >> 24) / 255)
    }

    static func argb(_ color: Color) -> UInt32 {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
        func b(_ c: CGFloat) -> UInt32 { UInt32((min(max(c, 0), 1) * 255).rounded()) }
        return b(ns.alphaComponent) << 24 | b(ns.redComponent) << 16 | b(ns.greenComponent) << 8 | b(ns.blueComponent)
    }

    /// `aarrggbb` or `rrggbb` (opaque), with or without a leading `#`.
    static func parseARGB(_ s: String) -> UInt32? {
        let t = s.trimmingCharacters(in: CharacterSet(charactersIn: " #"))
        guard t.count == 6 || t.count == 8, let v = UInt32(t, radix: 16) else { return nil }
        return t.count == 6 ? 0xff000000 | v : v
    }

    /// What the hex field shows: `RRGGBB` when opaque, `AARRGGBB` otherwise (as R3WRK does).
    static func hexString(_ v: UInt32) -> String {
        v >> 24 == 0xff ? String(format: "%06X", v & 0xffffff) : String(format: "%08X", v)
    }

    // MARK: Clipboard

    /// `THEME name=<name>;<string>` — what R3WRK's Copy button writes too.
    func clipboardText(name: String) -> String {
        "THEME name=\(name.replacingOccurrences(of: ";", with: ""));\(string)"
    }

    /// Parses clipboard text (with or without the `THEME` prefix). Nil if it holds no theme key.
    static func fromClipboardText(_ text: String) -> (palette: ThemePalette, name: String?)? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("THEME") { t = String(t.dropFirst(5)) }
        var name: String?
        var rest: [Substring] = []
        for token in t.split(separator: ";") {
            let trimmed = token.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("name=") { name = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
            else { rest.append(token) }
        }
        var p = ThemePalette()
        guard p.apply(rest.joined(separator: ";")) > 0 else { return nil }
        return (p, name?.isEmpty == true ? nil : name)
    }

    // MARK: Legacy + built-ins

    /// Sieve's old four-colour scheme in the shared format: surface → panelBg, bars → windowBg,
    /// divider → gridLine, accent → accent + waveform; the rest is Midnight, with Paper's dark text
    /// swapped in on a light surface.
    static func fromLegacy(surface: String, chrome: String, divider: String, accent: String) -> ThemePalette {
        var p = ThemePalette()
        if let v = parseARGB(surface) { p["panelBg"] = v }
        if let v = parseARGB(chrome) { p["windowBg"] = v }
        if let v = parseARGB(divider) { p["gridLine"] = v }
        if let v = parseARGB(accent) { p["accent"] = v; p["waveform"] = v }
        if luminance(p["panelBg"]) >= 0.5 {
            p["screenText"] = 0xff1f242b; p["screenTextDim"] = 0xff6f7680
            p["text"] = 0xff1f242b; p["textDim"] = 0xff6f7680
        }
        return p
    }

    static func luminance(_ v: UInt32) -> Double {
        0.299 * Double((v >> 16) & 0xFF) / 255 + 0.587 * Double((v >> 8) & 0xFF) / 255 + 0.114 * Double(v & 0xFF) / 255
    }

    /// Kept identical to R3WRK's `kBuiltIns` (Theme.cpp) so both apps list the same starting points.
    static let builtIns: [(name: String, spec: String)] = [
        ("Midnight",
         "windowBg:ff14161a;panelBg:ff17191e;waveform:ff5ec2ff;accent:ff5ec2ff;"
         + "zeroLine:29ffffff;gridLine:80000000;playhead:ffff3b30;loopMarker:ffffa500;"
         + "recordButton:ff8b0000;text:ffe0e0e0;textDim:ff888888;"
         + "screenText:ffe0e0e0;screenTextDim:ff888888"),
        ("Slate",
         "windowBg:ff2a2e35;panelBg:ff232830;waveform:ff9db8d0;accent:ff8aa9c8;"
         + "zeroLine:22ffffff;gridLine:66000000;playhead:ffff5b52;loopMarker:ffe6a552;"
         + "recordButton:ff9e4444;text:ffdfe4ea;textDim:ff9aa3ad;"
         + "screenText:ffdfe4ea;screenTextDim:ff9aa3ad"),
        ("Graphite",
         "windowBg:ff1b1b1d;panelBg:ff202022;waveform:ffbfc2c8;accent:ff9a9aa2;"
         + "zeroLine:20ffffff;gridLine:70000000;playhead:ffff453a;loopMarker:ffd8a53a;"
         + "recordButton:ff8a3a3a;text:ffe6e6e8;textDim:ff8c8c92;"
         + "screenText:ffe6e6e8;screenTextDim:ff8c8c92"),
        ("Amber",
         "windowBg:ff15120d;panelBg:ff1b1712;waveform:ffe0a35a;accent:ffffb454;"
         + "zeroLine:22ffffff;gridLine:66000000;playhead:ffff6a4d;loopMarker:ffffd24d;"
         + "recordButton:ff8a3d1f;text:ffece2d2;textDim:ff9a8f7d;"
         + "screenText:ffece2d2;screenTextDim:ff9a8f7d"),
        ("Paper",
         "windowBg:fff4f2ec;panelBg:ffe9e6de;waveform:ff2f6ea5;accent:ff2f6ea5;"
         + "zeroLine:18000000;gridLine:28000000;playhead:ffd0402c;loopMarker:ffc07f18;"
         + "recordButton:ffb23b3b;text:ff1f242b;textDim:ff6f7680;"
         + "screenText:ff1f242b;screenTextDim:ff6f7680"),
        ("Madrona",
         "windowBg:ff8797ac;panelBg:ff17191e;waveform:ff5ec2ff;accent:ffd4a24a;"
         + "zeroLine:29ffffff;gridLine:80000000;playhead:ffff3b30;loopMarker:ffffa500;"
         + "recordButton:ffc1503a;text:ff1b2433;textDim:ff46536a;"
         + "screenText:ffe0e0e0;screenTextDim:ff888888"),
        ("Silver",
         "windowBg:ffc9cbce;panelBg:ff17191e;waveform:ff5ec2ff;accent:ff2f6ea5;"
         + "zeroLine:29ffffff;gridLine:80000000;playhead:ffff3b30;loopMarker:ffffa500;"
         + "recordButton:ff8b0000;text:ff2b2c2e;textDim:ff6e6f72;"
         + "screenText:ffe0e0e0;screenTextDim:ff888888;shadedPanel:1;"
         + "edgeShadeDarken:0.85;edgeShadeAlpha:0.42"),
        ("Ableton Dark Blue-Grey",
         "windowBg:ff293238;panelBg:ff37474f;gridLine:ff2c3a42;accent:fff5b854;waveform:fff5b854"),
        ("Charcoal",
         "windowBg:ff2e2e2e;panelBg:ff434343;gridLine:ff363636;accent:fff5b854;waveform:fff5b854"),
        ("Neutral Grey",
         "windowBg:ff3a3a3a;panelBg:ff616161;gridLine:ff4e4e4e;accent:fff5b854;waveform:fff5b854"),
        ("Slate Blue",
         "windowBg:ff21252e;panelBg:ff2e3440;gridLine:ff262b36;accent:ff88c0d0;waveform:ff88c0d0"),
        ("Warm Graphite",
         "windowBg:ff262322;panelBg:ff3a3736;gridLine:ff302c2b;accent:ffe0a24e;waveform:ffe0a24e"),
        ("Soft Grey",
         "windowBg:ff66666a;panelBg:ff46464b;gridLine:ff363636;accent:ffe7eaec;waveform:ffe7eaec"),
    ]

    static func builtIn(_ name: String) -> ThemePalette? {
        builtIns.first { $0.name == name }.map { ThemePalette(string: $0.spec) }
    }
}

// MARK: - ThemeLibrary

/// The saved-theme folder shared with R3WRK: `~/Library/Application Support/Shared Themes/`,
/// one `<name>.theme` file per theme holding `ThemePalette.string`. Sieve is sandboxed, so it
/// reaches the real folder (not its container's) through a home-relative temporary-exception
/// entitlement for exactly this path — see Sieve.entitlements.
enum ThemeLibrary {
    static let activeKey = "themePalette"

    static var directory: URL {
        // `homeDirectoryForCurrentUser` is the sandbox container; the entitlement names a path
        // under the real home, so resolve that from the password database.
        let home = getpwuid(getuid()).flatMap { String(validatingUTF8: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        return URL(fileURLWithPath: home)
            .appending(path: "Library/Application Support/Shared Themes", directoryHint: .isDirectory)
    }

    private static func file(_ name: String, in dir: URL) -> URL {
        let safe = name.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return dir.appending(path: safe + ".theme")
    }

    static func names(in dir: URL = directory) -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "theme" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    static func load(_ name: String, in dir: URL = directory) -> ThemePalette? {
        (try? String(contentsOf: file(name, in: dir), encoding: .utf8)).map(ThemePalette.init(string:))
    }

    @discardableResult
    static func save(_ palette: ThemePalette, as name: String, in dir: URL = directory) -> Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (try? palette.string.write(to: file(name, in: dir), atomically: true, encoding: .utf8)) != nil
    }

    static func delete(_ name: String, in dir: URL = directory) {
        try? FileManager.default.removeItem(at: file(name, in: dir))
    }

    static func copyToClipboard(_ palette: ThemePalette, name: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(palette.clipboardText(name: name), forType: .string)
    }

    static func pasteFromClipboard() -> (palette: ThemePalette, name: String?)? {
        NSPasteboard.general.string(forType: .string).flatMap(ThemePalette.fromClipboardText)
    }

    /// First launch after the switch to shared themes: turn the old four `custom*Hex` settings
    /// into the single `themePalette` string, so the colours you had carry over unchanged.
    static func migrateLegacySettings(_ defaults: UserDefaults = .standard) {
        guard defaults.string(forKey: activeKey) == nil else { return }
        let old = ["customSurfaceHex": "#37474F", "customChromeHex": "#293238",
                   "customDividerHex": "#2C3A42", "customAccentHex": "#F5B854"]
        func v(_ k: String) -> String { defaults.string(forKey: k) ?? old[k]! }
        let p = ThemePalette.fromLegacy(surface: v("customSurfaceHex"), chrome: v("customChromeHex"),
                                        divider: v("customDividerHex"), accent: v("customAccentHex"))
        defaults.set(p.string, forKey: activeKey)
    }
}
