import Foundation
import Testing
@testable import Sieve

struct AudioClipTests {
    private func clip(frames n: Int, channels c: Int = 1, rate: Double = 48_000,
                      _ value: (Int) -> Float = { _ in 0.5 }) -> AudioClip {
        AudioClip(channels: (0..<c).map { _ in (0..<n).map(value) }, sampleRate: rate)
    }

    @Test func cropKeepsSelectedRange() {
        let c = clip(frames: 100) { Float($0) }.cropped(to: 10..<20)
        #expect(c.frameCount == 10)
        #expect(c.channels[0].first == 10)
        #expect(c.channels[0].last == 19)
    }

    @Test func deleteJoinsSides() {
        let c = clip(frames: 100) { Float($0) }.removingRange(40..<60)
        #expect(c.frameCount == 80)
        #expect(c.channels[0][39] == 39)
        #expect(c.channels[0][40] == 60)
    }

    @Test func amplifyBySixDbRoughlyDoubles() {
        let c = clip(frames: 64) { _ in 0.25 }.amplified(db: 6.0206, in: 0..<64)
        #expect(abs(c.channels[0][0] - 0.5) < 0.001)
    }

    @Test func normalizeBringsPeakToTarget() {
        let a = clip(frames: 64) { $0 == 10 ? 0.2 : 0.05 }
        let peak = a.normalizedToPeak(db: -6.0206, in: 0..<64).peakLinear(in: 0..<64)
        #expect(abs(peak - 0.5) < 0.002)
    }

    @Test func reverseIsInvolution() {
        let a = clip(frames: 50) { Float($0) }
        #expect(a.reversed(in: 0..<50).reversed(in: 0..<50).channels[0] == a.channels[0])
    }

    @Test func reverseSubrangeOnlyTouchesRange() {
        let c = clip(frames: 10) { Float($0) }.reversed(in: 2..<6)
        #expect(c.channels[0] == [0, 1, 5, 4, 3, 2, 6, 7, 8, 9])
    }

    @Test func silenceZerosRange() {
        let c = clip(frames: 20) { _ in 0.8 }.silenced(in: 5..<10)
        #expect(c.channels[0][4] == 0.8)
        #expect(c.channels[0][5..<10].allSatisfy { $0 == 0 })
        #expect(c.channels[0][10] == 0.8)
    }

    @Test func fadeInRunsZeroToUnity() {
        let c = clip(frames: 100) { _ in 1 }.fadedIn(in: 0..<100)
        #expect(c.channels[0][0] < 0.001)
        #expect(abs(c.channels[0][99] - 1) < 0.001)
        #expect(c.channels[0][50] > 0.4 && c.channels[0][50] < 0.6)
    }

    @Test func fadeOutMirrorsFadeIn() {
        let c = clip(frames: 100) { _ in 1 }.fadedOut(in: 0..<100)
        #expect(abs(c.channels[0][0] - 1) < 0.001)
        #expect(c.channels[0][99] < 0.001)
    }

    @Test func pasteReplacesRangeKeepingLengthWhenSizesMatch() {
        let a = clip(frames: 100) { _ in 0.1 }
        let ins = clip(frames: 10) { _ in 0.9 }
        let c = a.replacingRange(20..<30, with: ins)
        #expect(c.frameCount == 100)
        #expect(c.channels[0][20..<30].allSatisfy { abs($0 - 0.9) < 0.001 })
    }

    @Test func pasteIntoZeroWidthInserts() {
        let c = clip(frames: 100) { _ in 0.1 }.replacingRange(50..<50, with: clip(frames: 10) { _ in 0.9 })
        #expect(c.frameCount == 110)
    }

    @Test func pasteResamplesToDestinationRate() {
        let a = clip(frames: 100, rate: 48_000) { _ in 0 }
        let ins = clip(frames: 100, rate: 24_000) { _ in 0.5 }   // half rate -> ~200 frames at 48k
        let c = a.replacingRange(0..<0, with: ins)
        #expect(c.frameCount == 300)                             // 100 original + 200 resampled
    }

    @Test func pasteMixesStereoClipboardIntoMonoClip() {
        let mono = clip(frames: 50, channels: 1) { _ in 0 }
        let stereo = clip(frames: 10, channels: 2) { _ in 0.4 }
        let c = mono.replacingRange(0..<0, with: stereo)
        #expect(c.channelCount == 1)
        #expect(c.frameCount == 60)
    }

    @Test func thumbnailSummaryHasShapeAndTracksAmplitude() {
        let summary = clip(frames: 4096, channels: 2) { _ in 0.5 }.thumbnailSummary(buckets: 128)
        #expect(summary.bucketCount == 128)
        #expect(summary.channels == 2)
        #expect(summary.peaks[0].allSatisfy { abs($0 - 0.5) < 0.01 })
        #expect(summary.rms[1].allSatisfy { abs($0 - 0.5) < 0.01 })
    }

    @Test func peakMipShrinksAndTracksExtremes() {
        let mip = PeakMip(clip(frames: 10_000) { $0 == 5_000 ? 1.0 : 0.1 }, base: 256, levelCount: 4)
        #expect(!mip.levels.isEmpty)
        let level = mip.levels[0]
        #expect(level.minMax[0][5_000 / level.stride].y >= 0.99)
        #expect(mip.level(forSamplesPerPixel: 1) == nil)
    }
}
