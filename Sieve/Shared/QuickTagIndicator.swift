import SwiftUI

/// Row indicator: the glyph + name for each Quick Tag a sample carries (`⚡ Kicks, 〰 Bass`),
/// or a dim dash when it has none. Read-only — assignment happens through the menu (list) or the
/// chips (inspector).
struct QuickTagIndicator: View {
    var mask: Int
    var slots: [QuickTag]

    var body: some View {
        if mask == 0 {
            Text("—").foregroundStyle(.tertiary)
        } else {
            let set = (0..<QuickTags.count).filter { QuickTags.isSet(mask, $0) }
            HStack(spacing: 6) {
                ForEach(Array(set.enumerated()), id: \.element) { idx, i in
                    HStack(spacing: 3) {
                        Image(systemName: QuickTags.symbolName(slots, i))
                            .imageScale(.small)
                            .foregroundStyle(.tint)
                        Text(QuickTags.displayName(slots, i)).lineLimit(1)
                    }
                    if idx < set.count - 1 {
                        Text(",").foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

extension Array {
    /// Bounds-checked subscript — nil instead of a trap.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
