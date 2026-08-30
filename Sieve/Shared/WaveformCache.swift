import Foundation

/// Decodes `WaveformSummary` blobs once and returns the cached value afterwards, so re-rendering
/// the sample table (scrolling, re-sorting, selection changes) doesn't re-parse every visible
/// row's Float16 blob. Main-actor only; entries are invalidated when the row's blob bytes change.
@MainActor
final class WaveformCache {
    private var store: [Int64: (data: Data?, summary: WaveformSummary?)] = [:]
    private let limit = 4_000

    func summary(id: Int64, data: Data?) -> WaveformSummary? {
        if let hit = store[id], hit.data == data { return hit.summary }
        if store.count >= limit { store.removeAll(keepingCapacity: true) }
        let decoded = data.flatMap(WaveformSummary.init(encoded:))
        store[id] = (data, decoded)
        return decoded
    }

    func clear() { store.removeAll(keepingCapacity: true) }
}
