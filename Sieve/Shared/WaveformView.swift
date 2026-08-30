import SwiftUI

/// Draws a WaveformSummary: one lane per channel (stereo split), peak outline + RMS body.
struct WaveformView: View {
    var summary: WaveformSummary?
    var playhead: Double? = nil          // 0...1
    var showGrid: Bool = false
    var accent: Color = .accentColor
    var onSeek: ((Double) -> Void)? = nil

    var body: some View {
        Canvas(rendersAsynchronously: true) { ctx, size in
            guard let summary, summary.bucketCount > 0 else {
                let mid = size.height / 2
                ctx.stroke(Path { $0.move(to: CGPoint(x: 0, y: mid)); $0.addLine(to: CGPoint(x: size.width, y: mid)) },
                           with: .color(.secondary.opacity(0.3)), lineWidth: 1)
                return
            }
            let lanes = summary.channels
            let laneH = size.height / CGFloat(lanes)
            let w = size.width
            let n = summary.bucketCount
            let step = w / CGFloat(n)

            for c in 0..<lanes {
                let top = CGFloat(c) * laneH
                let mid = top + laneH / 2
                let half = laneH / 2 - 0.5
                if showGrid {
                    // -6 dB and -12 dB gridlines
                    for db in [-6.0, -12.0] {
                        let a = CGFloat(pow(10, db / 20)) * half
                        var g = Path()
                        g.move(to: CGPoint(x: 0, y: mid - a)); g.addLine(to: CGPoint(x: w, y: mid - a))
                        g.move(to: CGPoint(x: 0, y: mid + a)); g.addLine(to: CGPoint(x: w, y: mid + a))
                        ctx.stroke(g, with: .color(.secondary.opacity(0.15)), lineWidth: 0.5)
                    }
                }
                var peakPath = Path()
                var rmsPath = Path()
                let peaks = summary.peaks[c], rms = summary.rms[c]
                peakPath.move(to: CGPoint(x: 0, y: mid))
                rmsPath.move(to: CGPoint(x: 0, y: mid))
                for i in 0..<n {
                    let x = CGFloat(i) * step
                    peakPath.addLine(to: CGPoint(x: x, y: mid - CGFloat(peaks[i]) * half))
                    rmsPath.addLine(to: CGPoint(x: x, y: mid - CGFloat(rms[i]) * half))
                }
                peakPath.addLine(to: CGPoint(x: w, y: mid))
                rmsPath.addLine(to: CGPoint(x: w, y: mid))
                for i in stride(from: n - 1, through: 0, by: -1) {
                    let x = CGFloat(i) * step
                    peakPath.addLine(to: CGPoint(x: x, y: mid + CGFloat(peaks[i]) * half))
                    rmsPath.addLine(to: CGPoint(x: x, y: mid + CGFloat(rms[i]) * half))
                }
                peakPath.closeSubpath(); rmsPath.closeSubpath()
                ctx.fill(peakPath, with: .color(accent.opacity(0.35)))
                ctx.fill(rmsPath, with: .color(accent.opacity(0.9)))
                if lanes > 1, c < lanes - 1 {
                    var sep = Path()
                    sep.move(to: CGPoint(x: 0, y: top + laneH)); sep.addLine(to: CGPoint(x: w, y: top + laneH))
                    ctx.stroke(sep, with: .color(.secondary.opacity(0.25)), lineWidth: 0.5)
                }
            }
            if let playhead {
                let x = CGFloat(playhead) * w
                var p = Path()
                p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height))
                ctx.stroke(p, with: .color(.primary), lineWidth: 1)
            }
        }
        .contentShape(Rectangle())
        .gesture(seekGesture)
    }

    private var seekGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onEnded { value in
                guard let onSeek else { return }
                onSeek(Double(value.location.x))
            }
    }
}

/// Wrapper that knows its width so seeks are expressed as 0...1.
struct SeekableWaveformView: View {
    var summary: WaveformSummary?
    var playhead: Double?
    var showGrid = true
    var onSeek: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            WaveformView(summary: summary, playhead: playhead, showGrid: showGrid) { x in
                onSeek(max(0, min(1, x / max(1, geo.size.width))))
            }
        }
    }
}
