import SwiftUI

/// The five oscillator waveforms offered as Quick Tag icons. SF Symbols has no square / saw /
/// triangle / noise wave, so they're drawn as paths (`OscWaveShape`) rather than shipped as
/// symbols. Stored in `QuickTag.symbol` under the `osc.` prefix, same as any SF Symbol name.
enum OscWaveform: String, CaseIterable {
    case sine     = "osc.sine"
    case square   = "osc.square"
    case saw      = "osc.saw"
    case triangle = "osc.triangle"
    case noise    = "osc.noise"
    case random   = "osc.random"

    var displayName: String {
        switch self {
        case .sine:     "Sine wave"
        case .square:   "Square wave"
        case .saw:      "Saw wave"
        case .triangle: "Triangle wave"
        case .noise:    "Noise"
        case .random:   "Random wave"
        }
    }
}

/// One Quick Tag icon: an SF Symbol, or — for an `osc.*` name — a drawn oscillator waveform
/// sized to sit next to text like a symbol would.
struct QuickTagGlyph: View {
    let symbol: String
    @ScaledMetric(relativeTo: .body) private var height: CGFloat = 11

    var body: some View {
        if let wave = OscWaveform(rawValue: symbol) {
            OscWaveShape(waveform: wave)
                .stroke(style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                .frame(width: height * 1.6, height: height)
                .accessibilityLabel(wave.displayName)
        } else {
            Image(systemName: symbol)
        }
    }
}

/// `Label` for Quick Tag slot `index`, with an SF Symbol or drawn-waveform icon.
struct QuickTagLabel: View {
    let slots: [QuickTag]
    let index: Int

    var body: some View {
        Label {
            Text(QuickTags.displayName(slots, index))
        } icon: {
            QuickTagGlyph(symbol: QuickTags.symbolName(slots, index))
        }
    }
}

/// Menu-item label for a Quick Tag slot. Native (AppKit) menus only take an `NSImage`, so the
/// drawn oscillator waveforms show as text alone there; SF Symbols keep their icon.
struct QuickTagMenuLabel: View {
    let slots: [QuickTag]
    let index: Int

    var body: some View {
        let name = QuickTags.symbolName(slots, index)
        let title = QuickTags.displayName(slots, index)
        if OscWaveform(rawValue: name) != nil {
            Text(title)
        } else {
            Label(title, systemImage: name)
        }
    }
}

/// Two cycles of the named waveform, filling `rect` (mid-line centred, full-height amplitude).
struct OscWaveShape: Shape {
    let waveform: OscWaveform

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width
        let mid = rect.midY
        let amp = rect.height / 2 - 0.7          // keep the stroke inside the frame
        let top = mid - amp
        let bot = mid + amp

        switch waveform {
        case .sine:
            let steps = 40
            for i in 0...steps {
                let x = w * CGFloat(i) / CGFloat(steps)
                let y = mid - amp * sin(4 * .pi * CGFloat(i) / CGFloat(steps))   // 2 cycles
                if i == 0 { p.move(to: CGPoint(x: x, y: y)) }
                else { p.addLine(to: CGPoint(x: x, y: y)) }
            }

        case .square:
            let q = w / 4
            p.move(to: CGPoint(x: 0, y: mid))
            p.addLine(to: CGPoint(x: 0, y: top))
            p.addLine(to: CGPoint(x: q, y: top))
            p.addLine(to: CGPoint(x: q, y: bot))
            p.addLine(to: CGPoint(x: 2 * q, y: bot))
            p.addLine(to: CGPoint(x: 2 * q, y: top))
            p.addLine(to: CGPoint(x: 3 * q, y: top))
            p.addLine(to: CGPoint(x: 3 * q, y: bot))
            p.addLine(to: CGPoint(x: w, y: bot))
            p.addLine(to: CGPoint(x: w, y: mid))

        case .saw:
            let half = w / 2
            p.move(to: CGPoint(x: 0, y: bot))
            p.addLine(to: CGPoint(x: half, y: top))
            p.addLine(to: CGPoint(x: half, y: bot))
            p.addLine(to: CGPoint(x: w, y: top))

        case .triangle:
            p.move(to: CGPoint(x: 0, y: mid))
            p.addLine(to: CGPoint(x: w * 0.125, y: top))
            p.addLine(to: CGPoint(x: w * 0.375, y: bot))
            p.addLine(to: CGPoint(x: w * 0.625, y: top))
            p.addLine(to: CGPoint(x: w * 0.875, y: bot))
            p.addLine(to: CGPoint(x: w, y: mid))

        case .noise:
            // A fixed jagged run — Shape.path must be pure, so no RNG.
            let offsets: [CGFloat] = [0.15, -0.75, 0.45, -0.2, 0.9, -0.55, 0.25,
                                      -0.95, 0.6, -0.35, 0.8, -0.65, 0.1]
            for (i, o) in offsets.enumerated() {
                let x = w * CGFloat(i) / CGFloat(offsets.count - 1)
                let y = mid + amp * o
                if i == 0 { p.move(to: CGPoint(x: x, y: y)) }
                else { p.addLine(to: CGPoint(x: x, y: y)) }
            }

        case .random:
            // Sample & hold: flat steps at fixed "random" heights, joined by vertical jumps.
            let levels: [CGFloat] = [0.35, -0.6, 0.9, -0.9, 0.15, 0.55]
            let stepW = w / CGFloat(levels.count)
            for (i, l) in levels.enumerated() {
                let y = mid - amp * l
                let x0 = stepW * CGFloat(i)
                if i == 0 { p.move(to: CGPoint(x: x0, y: y)) }
                else { p.addLine(to: CGPoint(x: x0, y: y)) }   // vertical jump from previous level
                p.addLine(to: CGPoint(x: x0 + stepW, y: y))    // hold
            }
        }
        return p
    }
}
