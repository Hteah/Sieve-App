import SwiftUI

/// Row indicator: just the glyph for each Quick Tag a sample carries (`⚡ 〰`), or a dim dash when it
/// has none. Names are carried in a hover tooltip and the accessibility label. Read-only —
/// assignment happens through the menu (list) or the chips (inspector).
struct QuickTagIndicator: View {
    var mask: Int
    var slots: [QuickTag]

    var body: some View {
        if mask == 0 {
            Text("—").foregroundStyle(.tertiary)
        } else {
            let set = (0..<QuickTags.count).filter { QuickTags.isSet(mask, $0) }
            let names = set.map { QuickTags.displayName(slots, $0) }.joined(separator: ", ")
            HStack(spacing: 6) {
                ForEach(set, id: \.self) { i in
                    Image(systemName: QuickTags.symbolName(slots, i))
                        .imageScale(.medium)
                        .foregroundStyle(.tint)
                }
            }
            .help(names)
            .accessibilityLabel(names)
        }
    }
}

extension Array {
    /// Bounds-checked subscript — nil instead of a trap.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
