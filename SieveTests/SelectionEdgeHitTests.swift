import Foundation
import Testing
@testable import Sieve

struct SelectionEdgeHitTests {
    private typealias Hit = EditorWaveformView.EdgeHit

    @Test func pressNearStartEdge() {
        #expect(EditorWaveformView.hitEdge(pressX: 102, startX: 100, endX: 300, tolerance: 8) == Hit.resizeStart)
    }

    @Test func pressNearEndEdge() {
        #expect(EditorWaveformView.hitEdge(pressX: 295, startX: 100, endX: 300, tolerance: 8) == Hit.resizeEnd)
    }

    @Test func pressInTheMiddleStartsANewSelection() {
        #expect(EditorWaveformView.hitEdge(pressX: 200, startX: 100, endX: 300, tolerance: 8) == Hit.newSelection)
    }

    @Test func tinySelectionPicksTheNearerEdge() {
        #expect(EditorWaveformView.hitEdge(pressX: 101, startX: 100, endX: 104, tolerance: 8) == Hit.resizeStart)
        #expect(EditorWaveformView.hitEdge(pressX: 103, startX: 100, endX: 104, tolerance: 8) == Hit.resizeEnd)
    }
}
