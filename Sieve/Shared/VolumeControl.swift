import SwiftUI

/// The one volume for everything Sieve plays, iTunes-style: quiet speaker · slider · loud speaker, always
/// visible at the top right of the main window (and in the pop-out editor's transport). Replaces the old
/// per-player speaker pop-ups (2026-10-07, Heath's choice). Bind it with `AppEnvironment.volumeBinding`.
struct ToolbarVolumeSlider: View {
    @Binding var volume: Double

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "speaker.fill")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Slider(value: $volume, in: 0...1)
                .controlSize(.small)
                .frame(width: 110)
            Image(systemName: "speaker.wave.3.fill")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .help("Volume: \(Int((volume * 100).rounded()))%")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Volume")
        .accessibilityValue("\(Int((volume * 100).rounded())) percent")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: volume = min(1, volume + 0.05)
            case .decrement: volume = max(0, volume - 0.05)
            @unknown default: break
            }
        }
    }
}
