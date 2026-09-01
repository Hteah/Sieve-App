import CoreGraphics
import Testing
@testable import Sieve

struct QuickTagsTests {
    @Test func oscillatorWaveformsAreOfferedAndDraw() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 60)
        for wave in OscWaveform.allCases {
            #expect(QuickTags.symbolChoices.contains(wave.rawValue))
            #expect(wave.rawValue.hasPrefix("osc."))
            #expect(!wave.displayName.isEmpty)
            #expect(!OscWaveShape(waveform: wave).path(in: rect).isEmpty)
        }
        // The picker filter must not drop these the way it drops unknown SF Symbols.
        #expect(OscWaveform(rawValue: "osc.saw") != nil)
        #expect(OscWaveform(rawValue: "waveform") == nil)
    }

    @Test func maskAndToggling() {
        for i in 0..<QuickTags.count {
            #expect(QuickTags.mask(i) == 1 << i)
            #expect(!QuickTags.isSet(0, i))
        }
        var mask = 0
        mask = QuickTags.toggling(mask, 2)
        #expect(QuickTags.isSet(mask, 2) && mask == 0b100)
        mask = QuickTags.toggling(mask, 4)
        #expect(mask == 0b10100)
        mask = QuickTags.toggling(mask, 2)
        #expect(!QuickTags.isSet(mask, 2) && mask == 0b10000)
    }

    @Test func loadPadsAndTruncatesToSix() {
        #expect(QuickTags.load("") == QuickTags.defaults)

        let three = QuickTags.encode([
            QuickTag(name: "Kicks", symbol: "waveform"),
            QuickTag(name: "Snares", symbol: "bolt.fill"),
            QuickTag(name: "Bass", symbol: "hexagon.fill"),
        ])
        let loadedThree = QuickTags.load(three)
        #expect(loadedThree.count == QuickTags.count)
        #expect(loadedThree[0] == QuickTag(name: "Kicks", symbol: "waveform"))
        #expect(loadedThree[3] == QuickTags.defaults[3])   // padded from defaults

        let eight = QuickTags.defaults + [QuickTag(name: "Extra", symbol: "star.fill"),
                                          QuickTag(name: "More", symbol: "drop.fill")]
        let loadedEight = QuickTags.load(QuickTags.encode(eight))
        #expect(loadedEight.count == QuickTags.count)
        #expect(loadedEight.last == QuickTags.defaults.last)
    }

    @Test func displayNameAndSymbolFallBack() {
        var slots = QuickTags.defaults
        slots[2].name = "   "
        slots[2].symbol = ""
        #expect(QuickTags.displayName(slots, 0) == "Tag 1")
        #expect(QuickTags.displayName(slots, 2) == "Quick Tag 3")
        #expect(QuickTags.displayName([], 5) == "Quick Tag 6")
        #expect(QuickTags.symbolName(slots, 2) == "circle.fill")
        #expect(QuickTags.symbolName([], 0) == "circle.fill")
        #expect(QuickTags.symbolChoices.contains(QuickTags.defaults[0].symbol))
    }
}
