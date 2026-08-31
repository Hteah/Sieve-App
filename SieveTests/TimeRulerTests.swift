import Foundation
import Testing
@testable import Sieve

struct TimeRulerTests {
    @Test func coarseIntervalWhenZoomedOut() {
        // 300 s across an 800 pt view -> ~8 labels max -> needs >= ~37 s spacing -> 60 s
        #expect(EditorWaveformView.tickInterval(visibleSeconds: 300, width: 800) == 60)
    }

    @Test func subSecondIntervalWhenZoomedIn() {
        // 0.8 s across 800 pt -> ~8 labels -> >= 0.1 s -> 0.1 s
        #expect(EditorWaveformView.tickInterval(visibleSeconds: 0.8, width: 800) == 0.1)
    }

    @Test func fallsBackToCoarsestForHugeSpans() {
        #expect(EditorWaveformView.tickInterval(visibleSeconds: 100_000, width: 400)
                == EditorWaveformView.tickCandidates.last!)
    }
}
