import Foundation
import Testing
@testable import Sieve

struct SampleSortTests {
    private func row(_ id: Int64, name: String, rate: Double?, bits: Int?) -> SampleRow {
        SampleRow(id: id, rootId: 1, relativePath: name, filename: name, parentDir: "", ext: "wav",
                  fileSize: 1, modifiedAt: .init(), audioHash: nil, fileHash: nil, durationSec: 1,
                  sampleRate: rate, channels: 2, bitDepth: bits, formatName: "WAV PCM", bpm: nil,
                  musicalKey: nil, waveform: nil, peakDb: nil, rmsDb: nil, clippedSamples: nil,
                  status: .present, rating: nil, isFavorite: nil, tagNames: nil)
    }

    @Test func sortsByRateAscendingThenReverses() {
        let rows = [
            row(1, name: "a", rate: 48_000, bits: 24),
            row(2, name: "b", rate: 44_100, bits: 16),
            row(3, name: "c", rate: 96_000, bits: 24),
        ]
        let asc = rows.sorted { SampleSort.rate.rowsAreInOrder($0, $1, ascending: true) }
        #expect(asc.map(\.id) == [2, 1, 3])
        let desc = rows.sorted { SampleSort.rate.rowsAreInOrder($0, $1, ascending: false) }
        #expect(desc.map(\.id) == [3, 1, 2])
    }

    @Test func unknownValuesAlwaysSortLast() {
        let rows = [
            row(1, name: "a", rate: nil, bits: nil),
            row(2, name: "b", rate: 44_100, bits: 16),
            row(3, name: "c", rate: 96_000, bits: 24),
        ]
        let asc = rows.sorted { SampleSort.bits.rowsAreInOrder($0, $1, ascending: true) }
        #expect(asc.map(\.id) == [2, 3, 1])
        let desc = rows.sorted { SampleSort.bits.rowsAreInOrder($0, $1, ascending: false) }
        #expect(desc.map(\.id) == [3, 2, 1])
    }

    @Test func tiesBreakByIdInBothDirections() {
        let rows = [
            row(6, name: "abc", rate: 48_000, bits: 24),
            row(5, name: "zed", rate: 48_000, bits: 24),
        ]
        let asc = rows.sorted { SampleSort.rate.rowsAreInOrder($0, $1, ascending: true) }
        #expect(asc.map(\.id) == [5, 6])
        let desc = rows.sorted { SampleSort.rate.rowsAreInOrder($0, $1, ascending: false) }
        #expect(desc.map(\.id) == [5, 6])
    }

    @Test func selectSnapsDirectionToFieldDefault() {
        var filter = SampleFilter()
        #expect(filter.sort == .name && filter.sortAscending)
        filter.select(.size)
        #expect(filter.sort == .size && !filter.sortAscending)  // size defaults to largest-first
        filter.select(.rate)
        #expect(filter.sort == .rate && filter.sortAscending)
        #expect(filter.samePredicate(as: SampleFilter()))       // sort changes don't change the predicate
    }
}
