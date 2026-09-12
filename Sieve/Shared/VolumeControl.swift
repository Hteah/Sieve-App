import SwiftUI

/// Compact volume control: a speaker glyph (reflecting the current level) that pops over a
/// slider on click, so it costs one icon's width in a toolbar/filter bar instead of a
/// permanently-visible slider. Used for both the list/browse preview and the editor player --
/// each keeps its own persisted level (see AppEnvironment.init / EditorSession.init for where
/// it's applied at launch) and just hands this view a plain 0...1 binding.
struct VolumeControl: View {
    @Binding var volume: Double

    @State private var showSlider = false

    private var symbolName: String {
        if volume <= 0.001 { "speaker.slash.fill" }
        else if volume < 0.34 { "speaker.wave.1.fill" }
        else if volume < 0.67 { "speaker.wave.2.fill" }
        else { "speaker.wave.3.fill" }
    }

    var body: some View {
        Button { showSlider.toggle() } label: {
            Image(systemName: symbolName)
                .frame(width: 16)
        }
        .help("Volume: \(Int((volume * 100).rounded()))%")
        .popover(isPresented: $showSlider, arrowEdge: .bottom) {
            HStack(spacing: 6) {
                Image(systemName: "speaker.fill")
                    .font(.caption2).foregroundStyle(.secondary)
                Slider(value: $volume, in: 0...1)
                Image(systemName: "speaker.wave.3.fill")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(10)
            .frame(width: 160)
        }
    }
}
