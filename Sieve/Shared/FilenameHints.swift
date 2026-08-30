import Foundation

/// Extracts BPM / musical key hints from sample filenames like
/// "Kick_128bpm_Cmin.wav", "loop 140 BPM F#m.wav", "Pad - Amaj - 90.wav".
enum FilenameHints {
    struct Result: Hashable, Sendable {
        var bpm: Double?
        var key: String?
    }

    nonisolated(unsafe) private static let bpmRegex = try! NSRegularExpression(
        pattern: #"(?<![\d.])(\d{2,3}(?:\.\d)?)\s?bpm\b|\bbpm\s?(\d{2,3}(?:\.\d)?)(?![\d.])"#,
        options: [.caseInsensitive])
    nonisolated(unsafe) private static let bareNumberRegex = try! NSRegularExpression(
        pattern: #"(?<![\d.\w])(6\d|7\d|8\d|9\d|1[0-9]\d)(?![\d.\w])"#)
    nonisolated(unsafe) private static let keyRegex = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z])([A-G])([#b♯♭]?)\s?(maj(?:or)?|min(?:or)?|m(?![a-z])|M(?![a-z]))?(?![A-Za-z])"#)

    static func parse(_ filename: String) -> Result {
        let stem = (filename as NSString).deletingPathExtension
        let cleaned = stem.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        let ns = cleaned as NSString
        let full = NSRange(location: 0, length: ns.length)
        var result = Result()

        if let m = bpmRegex.firstMatch(in: cleaned, range: full) {
            for g in 1...2 {
                let r = m.range(at: g)
                if r.location != NSNotFound, let v = Double(ns.substring(with: r)) { result.bpm = v; break }
            }
        } else if let m = bareNumberRegex.firstMatch(in: cleaned, range: full) {
            // A lone 60–199 number is very likely a tempo in sample-pack naming.
            result.bpm = Double(ns.substring(with: m.range(at: 1)))
        }

        for m in keyRegex.matches(in: cleaned, range: full) {
            let note = ns.substring(with: m.range(at: 1))
            let accRange = m.range(at: 2)
            var acc = accRange.location != NSNotFound ? ns.substring(with: accRange) : ""
            let qualRange = m.range(at: 3)
            let qual = qualRange.location != NSNotFound ? ns.substring(with: qualRange) : ""
            // Require either an accidental or a quality word so a bare "A"/"C" in a word list doesn't match.
            guard !acc.isEmpty || !qual.isEmpty else { continue }
            acc = acc.replacingOccurrences(of: "♯", with: "#").replacingOccurrences(of: "♭", with: "b")
            let isMinor = qual.lowercased().hasPrefix("min") || qual == "m"
            result.key = note + acc + (isMinor ? "m" : "")
            break
        }
        return result
    }
}
