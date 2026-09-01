import AppKit
import SwiftUI

/// Ableton-style icon grid: pick one SF Symbol from `QuickTags.symbolChoices`. Calls `onPick` and
/// dismisses itself.
struct SymbolGridPicker: View {
    var title: String
    var selected: String
    var onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    private let columns = Array(repeating: GridItem(.fixed(34), spacing: 6), count: 8)

    /// Drawn oscillator waveforms, plus the SF Symbols the running OS actually ships
    /// (invalid names would render blank).
    private var choices: [String] {
        QuickTags.symbolChoices.filter {
            OscWaveform(rawValue: $0) != nil
                || NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            ScrollView {
                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(choices, id: \.self) { name in
                        Button {
                            onPick(name)
                            dismiss()
                        } label: {
                            QuickTagGlyph(symbol: name)
                                .imageScale(.medium)
                                .frame(width: 34, height: 34)
                                .background(name == selected ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.08),
                                            in: RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(name == selected ? Color.accentColor : .clear, lineWidth: 1.5))
                        }
                        .buttonStyle(.plain)
                        .help(OscWaveform(rawValue: name)?.displayName ?? name)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(height: 220)
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 340)
    }
}
