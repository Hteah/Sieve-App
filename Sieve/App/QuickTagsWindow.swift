import SwiftUI

/// The Quick Tags window (Sieve ▸ Quick Tags…): name and icon for each of the six slots.
/// Moved out of Settings, which was getting crowded — same controls, same storage.
struct QuickTagsWindow: View {
    @Environment(\.palette) private var palette
    @AppStorage(QuickTags.storageKey) private var quickTagSlotsJSON = ""
    @State private var quickTagSlots: [QuickTag] = QuickTags.defaults
    @State private var iconPickerSlot: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(0..<QuickTags.count, id: \.self) { i in
                    HStack(spacing: 8) {
                        Button {
                            iconPickerSlot = i
                        } label: {
                            QuickTagGlyph(symbol: QuickTags.symbolName(quickTagSlots, i))
                                .frame(width: 26, height: 26)
                                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
                        }
                        .buttonStyle(.plain)
                        .help("Choose an icon")
                        TextField("", text: nameBinding(i), prompt: Text("Name"))
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }
            HStack {
                Text("Tag samples with these from the list, the inspector, or by dragging onto one in the sidebar.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Reset to defaults") { setSlots(QuickTags.defaults) }
                    .controlSize(.small)
                    .disabled(quickTagSlots == QuickTags.defaults)
            }
        }
        .padding(16)
        .frame(width: 360)
        .background(palette.surface)
        .onAppear { quickTagSlots = QuickTags.load(quickTagSlotsJSON) }
        .onChange(of: quickTagSlotsJSON) { _, new in
            let loaded = QuickTags.load(new)
            if loaded != quickTagSlots { quickTagSlots = loaded }
        }
        .sheet(isPresented: Binding(get: { iconPickerSlot != nil }, set: { if !$0 { iconPickerSlot = nil } })) {
            if let slot = iconPickerSlot {
                SymbolGridPicker(
                    title: "Icon for \(QuickTags.displayName(quickTagSlots, slot))",
                    selected: QuickTags.symbolName(quickTagSlots, slot)
                ) { symbol in
                    var s = quickTagSlots
                    s[slot].symbol = symbol
                    setSlots(s)
                }
            }
        }
    }

    private func setSlots(_ slots: [QuickTag]) {
        quickTagSlots = slots
        quickTagSlotsJSON = QuickTags.encode(slots)
    }

    private func nameBinding(_ i: Int) -> Binding<String> {
        Binding(
            get: { quickTagSlots.indices.contains(i) ? quickTagSlots[i].name : "" },
            set: { var s = quickTagSlots; s[i].name = $0; setSlots(s) }
        )
    }
}
