import Foundation

enum Fmt {
    static func duration(_ s: Double?) -> String {
        guard let s else { return "–" }
        if s < 10 { return String(format: "%.2fs", s) }
        if s < 60 { return String(format: "%.1fs", s) }
        let m = Int(s) / 60, sec = Int(s) % 60
        return String(format: "%d:%02d", m, sec)
    }
    static func bytes(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }
    static func db(_ v: Double?) -> String {
        guard let v else { return "–" }
        if v <= -120 { return "-∞ dB" }
        return String(format: "%.1f dB", v)
    }
    static func sampleRate(_ v: Double?) -> String {
        guard let v else { return "–" }
        return v.truncatingRemainder(dividingBy: 1000) == 0 ? "\(Int(v / 1000)) kHz" : String(format: "%.1f kHz", v / 1000)
    }
    static func channels(_ c: Int?) -> String {
        switch c { case nil: "–"; case 1: "Mono"; case 2: "Stereo"; case let n?: "\(n) ch" }
    }
}
