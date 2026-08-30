import Testing
@testable import Sieve

struct FilenameHintsTests {
    @Test(arguments: [
        ("Kick_128bpm_Cmin.wav", 128.0, "Cm"),
        ("loop 140 BPM F#m.wav", 140.0, "F#m"),
        ("Pad - Amaj - 90.wav", 90.0, "A"),
        ("Snare_Tight_01.wav", nil, nil),
        ("Bass 174bpm Ebmin.flac", 174.0, "Ebm"),
        ("vox_Gmajor_120.5bpm.aif", 120.5, "G"),
        ("909 clap.wav", nil, nil),
    ] as [(String, Double?, String?)])
    func parses(name: String, bpm: Double?, key: String?) {
        let r = FilenameHints.parse(name)
        #expect(r.bpm == bpm)
        #expect(r.key == key)
    }
}
