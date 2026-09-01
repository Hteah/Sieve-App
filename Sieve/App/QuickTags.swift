import Foundation

/// One of the six user-defined "Quick Tag" slots: a name plus an SF Symbol used as its glyph
/// everywhere the tag appears. Stored as a JSON array in `UserDefaults` under `quickTagSlots`;
/// the per-sample assignment is a 6-bit mask on `annotation.quickTags`.
struct QuickTag: Codable, Hashable, Sendable {
    var name: String
    var symbol: String
}

enum QuickTags {
    static let count = 6
    static let storageKey = "quickTagSlots"

    static let defaults: [QuickTag] = [
        QuickTag(name: "Tag 1", symbol: "bolt.fill"),
        QuickTag(name: "Tag 2", symbol: "waveform"),
        QuickTag(name: "Tag 3", symbol: "hexagon.fill"),
        QuickTag(name: "Tag 4", symbol: "triangle.fill"),
        QuickTag(name: "Tag 5", symbol: "diamond.fill"),
        QuickTag(name: "Tag 6", symbol: "sparkles"),
    ]

    /// Curated glyphs — music / audio / electronic, then geometric — offered in the icon picker.
    /// The picker filters this to names the running OS actually ships, so it's safe to be generous.
    static let symbolChoices: [String] = [
        // Waveforms & signal
        "waveform", "waveform.circle.fill", "waveform.path", "waveform.path.ecg",
        "waveform.badge.plus", "waveform.badge.mic", "waveform.slash",
        "wave.3.forward", "wave.3.left", "wave.3.right",
        // Notes & instruments
        "music.note", "music.note.list", "music.quarternote.3", "music.mic",
        "tuningfork", "pianokeys", "pianokeys.inverse", "guitars.fill", "amplifier",
        // Playback / speakers / headphones
        "speaker.wave.2.fill", "speaker.wave.3.fill", "hifispeaker.fill", "hifispeaker.2.fill",
        "headphones", "radio.fill",
        "recordingtape", "recordingtape.circle", "opticaldisc.fill", "opticaldiscdrive.fill",
        // Mic / recording / meters
        "mic.fill", "mic.circle.fill", "mic.and.signal.meter.fill", "gauge.with.dots.needle.bottom.50percent",
        // Controls / studio
        "slider.horizontal.3", "slider.vertical.3", "dial.low.fill", "dial.medium.fill", "dial.high.fill",
        "switch.2",
        // Electronic / hardware
        "bolt.fill", "bolt.horizontal.fill", "bolt.circle.fill", "powerplug.fill",
        "cable.connector", "cable.coaxial", "cpu.fill", "memorychip.fill",
        "fanblades.fill", "gearshape.fill", "gearshape.2.fill", "camera.aperture",
        "point.3.connected.trianglepath.dotted", "point.3.filled.connected.trianglepath.dotted",
        "circle.hexagongrid.fill", "circle.grid.cross.fill", "circle.grid.3x3.fill",
        // Flair / abstract
        "sparkles", "sparkle", "burst.fill", "fireworks", "atom", "function", "scope", "rays",
        // Geometric (Ableton-box feel)
        "hexagon.fill", "triangle.fill", "diamond.fill", "square.fill", "pentagon.fill",
        "octagon.fill", "seal.fill", "star.fill", "rhombus.fill", "circle.fill",
        "capsule.fill", "app.fill",
    ]

    /// Decode the stored JSON, always returning exactly `count` slots (padded from `defaults`).
    static func load(_ json: String) -> [QuickTag] {
        var slots = defaults
        if let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([QuickTag].self, from: data) {
            for i in 0..<count where i < decoded.count {
                slots[i] = decoded[i]
            }
        }
        return slots
    }

    static func encode(_ slots: [QuickTag]) -> String {
        (try? JSONEncoder().encode(slots)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    /// Name for slot `i`, falling back to a generic label when the user cleared it.
    static func displayName(_ slots: [QuickTag], _ i: Int) -> String {
        let trimmed = slots[safe: i]?.name.trimmingCharacters(in: .whitespaces) ?? ""
        return trimmed.isEmpty ? "Quick Tag \(i + 1)" : trimmed
    }

    /// SF Symbol for slot `i`, with a safe fallback.
    static func symbolName(_ slots: [QuickTag], _ i: Int) -> String {
        let s = slots[safe: i]?.symbol ?? ""
        return s.isEmpty ? "circle.fill" : s
    }

    // MARK: Bit mask

    static func mask(_ i: Int) -> Int { 1 << i }
    static func isSet(_ mask: Int, _ i: Int) -> Bool { mask & self.mask(i) != 0 }
    static func toggling(_ mask: Int, _ i: Int) -> Int { mask ^ self.mask(i) }
}
