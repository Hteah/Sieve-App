import SwiftUI

/// Interactive waveform for the audio editor: draws the actual samples (via `PeakMip` when
/// zoomed out), a drag-to-select region bound to the session, and the playhead. Independent of
/// `Sieve/Shared/WaveformView.swift`, which the list and duplicates views still use.
struct EditorWaveformView: View {
    let clip: AudioClip
    let mip: PeakMip?
    @Binding var selection: Range<Int>?
    @Binding var zoom: Double            // 1 = whole clip fits; capped by the caller
    var playheadFrame: Int?

    @State private var dragAnchor: Int?

    var body: some View {
        GeometryReader { geo in
            let baseWidth = max(1, geo.size.width)
            let contentWidth = baseWidth * CGFloat(max(1, zoom))
            ScrollView(.horizontal, showsIndicators: true) {
                Canvas(rendersAsynchronously: true) { ctx, size in
                    drawWaveform(ctx: ctx, size: size)
                    drawSelection(ctx: ctx, size: size)
                    drawPlayhead(ctx: ctx, size: size)
                }
                .frame(width: contentWidth, height: geo.size.height)
                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
                .highPriorityGesture(selectGesture(width: contentWidth))
                .onTapGesture(count: 2) {
                    if clip.frameCount > 0 { selection = 0..<clip.frameCount }
                }
            }
            .scrollIndicators(.visible)
        }
    }

    // MARK: Interaction

    private func frame(at x: CGFloat, width: CGFloat) -> Int {
        let n = max(1, clip.frameCount)
        return min(n, max(0, Int((x / max(1, width)) * CGFloat(n))))
    }

    private func selectGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragAnchor == nil { dragAnchor = frame(at: value.startLocation.x, width: width) }
                let a = dragAnchor ?? frame(at: value.location.x, width: width)
                let b = frame(at: value.location.x, width: width)
                let lo = min(a, b), hi = max(a, b)
                selection = lo < hi ? lo..<hi : nil
            }
            .onEnded { value in
                if abs(value.translation.width) < 3 { selection = nil }   // a click clears the selection
                dragAnchor = nil
            }
    }

    // MARK: Drawing

    private func drawWaveform(ctx: GraphicsContext, size: CGSize) {
        let n = clip.frameCount
        let lanes = max(1, clip.channelCount)
        let laneHeight = size.height / CGFloat(lanes)
        guard n > 0, size.width >= 1 else {
            var line = Path()
            line.move(to: CGPoint(x: 0, y: size.height / 2))
            line.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            ctx.stroke(line, with: .color(.secondary.opacity(0.3)), lineWidth: 1)
            return
        }
        let columns = Int(size.width.rounded(.up))
        let spp = Double(n) / Double(max(1, columns))
        let level = mip?.level(forSamplesPerPixel: spp)

        for c in 0..<lanes {
            let top = CGFloat(c) * laneHeight
            let mid = top + laneHeight / 2
            let half = laneHeight / 2 - 1

            var wave = Path()
            for px in 0..<columns {
                let f0 = min(n - 1, Int(Double(px) * spp))
                let f1 = min(n, max(f0 + 1, Int(Double(px + 1) * spp)))
                var lo: Float = 0
                var hi: Float = 0
                if let level, c < level.minMax.count, !level.minMax[c].isEmpty {
                    let bins = level.minMax[c]
                    let b0 = min(bins.count - 1, f0 / level.stride)
                    let b1 = min(bins.count - 1, (f1 - 1) / level.stride)
                    lo = bins[b0].x; hi = bins[b0].y
                    if b1 > b0 {
                        for b in (b0 + 1)...b1 {
                            lo = min(lo, bins[b].x)
                            hi = max(hi, bins[b].y)
                        }
                    }
                } else if c < clip.channels.count {
                    let ch = clip.channels[c]
                    lo = ch[f0]; hi = ch[f0]
                    var i = f0 + 1
                    while i < f1 {
                        let v = ch[i]
                        if v < lo { lo = v }
                        if v > hi { hi = v }
                        i += 1
                    }
                }
                let x = CGFloat(px) + 0.5
                wave.move(to: CGPoint(x: x, y: mid - CGFloat(hi) * half))
                wave.addLine(to: CGPoint(x: x, y: mid - CGFloat(lo) * half))
            }
            ctx.stroke(wave, with: .color(.accentColor), lineWidth: 1)

            var zero = Path()
            zero.move(to: CGPoint(x: 0, y: mid))
            zero.addLine(to: CGPoint(x: size.width, y: mid))
            ctx.stroke(zero, with: .color(.secondary.opacity(0.25)), lineWidth: 0.5)

            if lanes > 1, c < lanes - 1 {
                var sep = Path()
                sep.move(to: CGPoint(x: 0, y: top + laneHeight))
                sep.addLine(to: CGPoint(x: size.width, y: top + laneHeight))
                ctx.stroke(sep, with: .color(.secondary.opacity(0.2)), lineWidth: 0.5)
            }
        }
    }

    private func drawSelection(ctx: GraphicsContext, size: CGSize) {
        guard let s = selection, !s.isEmpty, clip.frameCount > 0 else { return }
        let n = CGFloat(clip.frameCount)
        let x0 = CGFloat(s.lowerBound) / n * size.width
        let x1 = CGFloat(s.upperBound) / n * size.width
        ctx.fill(Path(CGRect(x: x0, y: 0, width: max(1, x1 - x0), height: size.height)),
                 with: .color(.accentColor.opacity(0.18)))
        for x in [x0, x1] {
            var edge = Path()
            edge.move(to: CGPoint(x: x, y: 0))
            edge.addLine(to: CGPoint(x: x, y: size.height))
            ctx.stroke(edge, with: .color(.accentColor.opacity(0.85)), lineWidth: 1)
        }
    }

    private func drawPlayhead(ctx: GraphicsContext, size: CGSize) {
        guard let f = playheadFrame, clip.frameCount > 0 else { return }
        let x = CGFloat(f) / CGFloat(clip.frameCount) * size.width
        var line = Path()
        line.move(to: CGPoint(x: x, y: 0))
        line.addLine(to: CGPoint(x: x, y: size.height))
        ctx.stroke(line, with: .color(.primary), lineWidth: 1)
    }
}
