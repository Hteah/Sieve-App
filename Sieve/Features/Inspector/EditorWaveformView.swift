import AppKit
import SwiftUI

/// Interactive waveform for the audio editor. Manages its own visible window (start frame + span)
/// so the mouse wheel can zoom toward the cursor and the canvas never grows to a huge size.
/// Drag to select, double-click to select all, wheel to zoom, shift/horizontal wheel to pan.
struct EditorWaveformView: View {
    let clip: AudioClip
    let mip: PeakMip?
    @Binding var selection: Range<Int>?
    var playheadFrame: Int?
    /// Pending amplify-slider gain (dB); the selected region is drawn scaled by it.
    @Binding var previewGainDb: Float
    /// Called with the clicked frame when the user clicks (not drags) the waveform.
    var onClickSeek: ((Int) -> Void)? = nil
    /// Called when a drag-selection finishes (the selection binding is already updated).
    var onSelectionCommitted: (() -> Void)? = nil
    /// Commits the pending `previewGainDb` to the audio.
    var onApplyGain: (() -> Void)? = nil
    /// Changes when a different file is loaded; resets the zoom/scroll window.
    var resetToken: AnyHashable?
    /// Draws an m:ss time ruler along the bottom (pop-out editor only).
    var showsTimeRuler = false

    @AppStorage("appTheme") private var themeRaw = AppTheme.system.rawValue
    private var accent: Color { AppTheme.current(themeRaw).waveformColor }

    @State private var visibleStart = 0
    @State private var visibleFrames = 0          // 0 => whole clip
    @State private var drag: DragState?

    private let minSpan = 16
    private let edgeTolerance: CGFloat = 8
    private let rulerHeight: CGFloat = 18

    enum EdgeHit { case newSelection, resizeStart, resizeEnd }

    /// `anchor`: for `.newSelection` the press frame; for a resize, the opposite (fixed) edge's frame.
    private struct DragState { var kind: EdgeHit; var anchor: Int }

    /// Which drag a press starts, given the pixel x of the press and of the selection's edges.
    nonisolated static func hitEdge(pressX: CGFloat, startX: CGFloat, endX: CGFloat, tolerance: CGFloat) -> EdgeHit {
        let dStart = abs(pressX - startX)
        let dEnd = abs(pressX - endX)
        guard dStart <= tolerance || dEnd <= tolerance else { return .newSelection }
        return dStart <= dEnd ? .resizeStart : .resizeEnd
    }

    var body: some View {
        GeometryReader { geo in
            let width = max(1, geo.size.width)
            let n = clip.frameCount
            let span = visibleFrames > 0 ? min(visibleFrames, n) : n
            let start = min(max(0, visibleStart), max(0, n - span))

            Canvas(rendersAsynchronously: true) { ctx, size in
                draw(ctx: ctx, size: size, start: start, span: max(1, span))
            }
            .frame(width: width, height: geo.size.height)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                InputCatcher(
                    onScroll: { dx, dy, x in
                        if abs(dx) > abs(dy) {
                            pan(pixels: dx, width: width, n: n, span: span, start: start)
                        } else {
                            zoom(factor: exp(-dy * 0.01), atX: x, width: width, n: n, span: span, start: start)
                        }
                    },
                    onDrag: { x, phase in handleDrag(x: x, phase: phase, width: width, span: span, start: start) },
                    onDoubleClick: { _ in if n > 0 { selection = 0..<n } },
                    edgeNearX: { x in nearSelectionEdge(x, width: width, span: span, start: start) }
                )
            }
            .overlay(alignment: .topTrailing) { zoomControls(width: width, n: n, span: span, start: start) }
            .overlay(alignment: .topLeading) { amplifyPanel(width: width, span: span, start: start) }
            .onChange(of: resetToken) { _, _ in visibleStart = 0; visibleFrames = 0 }
            .onChange(of: clip.frameCount) { _, newValue in
                if visibleFrames > newValue { visibleFrames = 0 }
                visibleStart = min(visibleStart, max(0, newValue - 1))
            }
        }
    }

    // MARK: Controls

    private func zoomControls(width: CGFloat, n: Int, span: Int, start: Int) -> some View {
        HStack(spacing: 1) {
            Button { zoom(factor: 0.5, atX: width / 2, width: width, n: n, span: span, start: start) } label: {
                Image(systemName: "minus")
            }
            Button("Fit") { visibleStart = 0; visibleFrames = 0 }
            Button { zoom(factor: 2, atX: width / 2, width: width, n: n, span: span, start: start) } label: {
                Image(systemName: "plus")
            }
        }
        .buttonStyle(.borderless)
        .font(.caption2)
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(.regularMaterial, in: Capsule())
        .padding(6)
    }

    // MARK: Interaction

    private func frame(atX x: CGFloat, width: CGFloat, span: Int, start: Int) -> Int {
        let frac = max(0, min(1, x / max(1, width)))
        return min(clip.frameCount, max(0, start + Int(frac * CGFloat(span))))
    }

    private func x(forFrame fr: Int, width: CGFloat, span: Int, start: Int) -> CGFloat {
        (CGFloat(fr - start) / CGFloat(max(1, span))) * width
    }

    private func nearSelectionEdge(_ px: CGFloat, width: CGFloat, span: Int, start: Int) -> Bool {
        guard let s = selection, !s.isEmpty else { return false }
        let sx = x(forFrame: s.lowerBound, width: width, span: span, start: start)
        let ex = x(forFrame: s.upperBound, width: width, span: span, start: start)
        return abs(px - sx) <= edgeTolerance || abs(px - ex) <= edgeTolerance
    }

    private func handleDrag(x px: CGFloat, phase: InputCatcher.Phase, width: CGFloat, span: Int, start: Int) {
        let f = frame(atX: px, width: width, span: span, start: start)
        switch phase {
        case .began:
            if let s = selection, !s.isEmpty {
                let sx = x(forFrame: s.lowerBound, width: width, span: span, start: start)
                let ex = x(forFrame: s.upperBound, width: width, span: span, start: start)
                switch Self.hitEdge(pressX: px, startX: sx, endX: ex, tolerance: edgeTolerance) {
                case .resizeStart: drag = DragState(kind: .resizeStart, anchor: s.upperBound)
                case .resizeEnd:   drag = DragState(kind: .resizeEnd, anchor: s.lowerBound)
                case .newSelection: drag = DragState(kind: .newSelection, anchor: f)
                }
            } else {
                drag = DragState(kind: .newSelection, anchor: f)
            }
        case .changed:
            guard let d = drag else { return }
            let lo = min(d.anchor, f), hi = max(d.anchor, f)
            switch d.kind {
            case .newSelection:
                selection = lo < hi ? lo..<hi : nil
            case .resizeStart, .resizeEnd:
                selection = lo..<max(hi, lo + 1)
            }
        case .ended:
            defer { drag = nil }
            guard let d = drag else { return }
            switch d.kind {
            case .newSelection:
                let framesPerPixel = Double(span) / Double(max(1, width))
                if abs(d.anchor - f) <= max(1, Int(3 * framesPerPixel)) {
                    selection = nil          // a click clears the selection…
                    onClickSeek?(f)          // …and moves the playhead here
                } else if selection != nil {
                    onSelectionCommitted?()  // a real drag-selection is now in place
                }
            case .resizeStart, .resizeEnd:
                onSelectionCommitted?()      // playback jumps to the adjusted selection
            }
        }
    }

    private func zoom(factor: Double, atX x: CGFloat, width: CGFloat, n: Int, span: Int, start: Int) {
        guard n > 0 else { return }
        let clamped = max(0.2, min(5, factor))
        let cursorFrac = Double(max(0, min(width, x)) / max(1, width))
        let cursorFrame = Double(start) + cursorFrac * Double(span)
        var newSpan = Int((Double(span) / clamped).rounded())
        newSpan = max(minSpan, min(n, newSpan))
        var newStart = Int((cursorFrame - cursorFrac * Double(newSpan)).rounded())
        newStart = max(0, min(n - newSpan, newStart))
        visibleFrames = newSpan == n ? 0 : newSpan
        visibleStart = newStart
    }

    @ViewBuilder
    private func amplifyPanel(width: CGFloat, span: Int, start: Int) -> some View {
        if let s = selection, !s.isEmpty {
            let rawX = x(forFrame: s.lowerBound, width: width, span: span, start: start)
            HStack(spacing: 6) {
                Image(systemName: "dial.low").font(.caption2).foregroundStyle(.secondary)
                Slider(value: $previewGainDb, in: -36...24).controlSize(.mini).frame(width: 120)
                Text(String(format: "%+.1f dB", previewGainDb))
                    .font(.caption2).monospacedDigit().frame(width: 54, alignment: .trailing)
                Button { onApplyGain?() } label: { Image(systemName: "checkmark") }
                    .disabled(previewGainDb == 0)
                    .help("Apply gain to the selection")
                Button { previewGainDb = 0 } label: { Image(systemName: "arrow.counterclockwise") }
                    .disabled(previewGainDb == 0)
                    .help("Reset")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.separator))
            .fixedSize()
            .offset(x: min(max(0, rawX), max(0, width - 260)) + 4, y: 4)
        }
    }

    private func pan(pixels dx: CGFloat, width: CGFloat, n: Int, span: Int, start: Int) {
        guard span < n else { return }
        let framesPerPixel = Double(span) / Double(max(1, width))
        var s = start - Int((Double(dx) * framesPerPixel).rounded())
        s = max(0, min(n - span, s))
        visibleFrames = span
        visibleStart = s
    }

    // MARK: Drawing

    private func draw(ctx: GraphicsContext, size: CGSize, start: Int, span: Int) {
        let n = clip.frameCount
        let lanes = max(1, clip.channelCount)
        guard n > 0, size.width >= 1 else {
            var line = Path()
            line.move(to: CGPoint(x: 0, y: size.height / 2))
            line.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            ctx.stroke(line, with: .color(.secondary.opacity(0.3)), lineWidth: 1)
            return
        }
        let plotH = showsTimeRuler ? max(1, size.height - rulerHeight) : size.height
        let laneHeight = plotH / CGFloat(lanes)
        let columns = Int(size.width.rounded(.up))
        let spp = Double(span) / Double(max(1, columns))
        let level = mip?.level(forSamplesPerPixel: spp)
        let end = min(n, start + span)

        // Live amplify-slider preview: scale only the columns overlapping the selection.
        let previewGain: Float = previewGainDb == 0 ? 1 : pow(10, previewGainDb / 20)
        let previewRange: Range<Int>? = (previewGain != 1) ? selection : nil

        func xForFrame(_ f: Int) -> CGFloat {
            (CGFloat(f - start) / CGFloat(max(1, span))) * size.width
        }

        for c in 0..<lanes {
            let top = CGFloat(c) * laneHeight
            let mid = top + laneHeight / 2
            let half = laneHeight / 2 - 1

            var wave = Path()
            for px in 0..<columns {
                let f0 = min(end - 1, start + Int(Double(px) * spp))
                let f1 = min(end, max(f0 + 1, start + Int(Double(px + 1) * spp)))
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
                } else if c < clip.channels.count, !clip.channels[c].isEmpty {
                    // No pyramid yet (just-loaded / mid-edit): scan raw, but sub-sample when a
                    // column covers a huge span so this stays smooth until the mip lands.
                    let ch = clip.channels[c]
                    let a0 = min(max(0, f0), ch.count - 1)
                    let a1 = min(max(a0 + 1, f1), ch.count)
                    let step = max(1, (a1 - a0) / 2048)
                    lo = ch[a0]; hi = ch[a0]
                    var i = a0 + step
                    while i < a1 {
                        let v = ch[i]
                        if v < lo { lo = v }
                        if v > hi { hi = v }
                        i += step
                    }
                }
                if let pr = previewRange, f1 > pr.lowerBound, f0 < pr.upperBound {
                    lo = max(-1, min(1, lo * previewGain))
                    hi = max(-1, min(1, hi * previewGain))
                }
                let x = CGFloat(px) + 0.5
                wave.move(to: CGPoint(x: x, y: mid - CGFloat(hi) * half))
                wave.addLine(to: CGPoint(x: x, y: mid - CGFloat(lo) * half))
            }
            ctx.stroke(wave, with: .color(accent), lineWidth: 1)

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

        if let s = selection, !s.isEmpty {
            let x0 = max(0, xForFrame(s.lowerBound))
            let x1 = min(size.width, xForFrame(s.upperBound))
            if x1 > 0, x0 < size.width, x1 > x0 {
                ctx.fill(Path(CGRect(x: x0, y: 0, width: max(1, x1 - x0), height: plotH)),
                         with: .color(accent.opacity(0.18)))
            }
            for (f, x) in [(s.lowerBound, xForFrame(s.lowerBound)), (s.upperBound, xForFrame(s.upperBound))]
            where f >= start && f <= end {
                var edge = Path()
                edge.move(to: CGPoint(x: x, y: 0))
                edge.addLine(to: CGPoint(x: x, y: plotH))
                ctx.stroke(edge, with: .color(accent.opacity(0.9)), lineWidth: 2)
                let hw: CGFloat = 5, hh: CGFloat = 14
                for cy in [hh / 2 + 1, plotH - hh / 2 - 1] {
                    ctx.fill(Path(roundedRect: CGRect(x: x - hw / 2, y: cy - hh / 2, width: hw, height: hh),
                                  cornerRadius: 2),
                             with: .color(accent))
                }
            }
        }

        if let f = playheadFrame, f >= start, f <= end {
            let x = xForFrame(f)
            var line = Path()
            line.move(to: CGPoint(x: x, y: 0))
            line.addLine(to: CGPoint(x: x, y: plotH))
            ctx.stroke(line, with: .color(.primary), lineWidth: 1)
        }

        if showsTimeRuler {
            drawRuler(ctx: ctx, size: size, plotH: plotH, start: start, span: span)
        }
    }

    // MARK: Time ruler

    nonisolated static let tickCandidates: [Double] =
        [0.05, 0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800]

    /// Smallest "nice" tick spacing (seconds) that keeps labels ≳ 90 pt apart.
    nonisolated static func tickInterval(visibleSeconds: Double, width: CGFloat) -> Double {
        let maxLabels = max(1, Double(width) / 90)
        let minInterval = visibleSeconds / maxLabels
        return tickCandidates.first { $0 >= minInterval } ?? tickCandidates.last!
    }

    private func drawRuler(ctx: GraphicsContext, size: CGSize, plotH: CGFloat, start: Int, span: Int) {
        let rate = clip.sampleRate
        guard rate > 0 else { return }

        ctx.fill(Path(CGRect(x: 0, y: plotH, width: size.width, height: size.height - plotH)),
                 with: .color(.secondary.opacity(0.08)))
        var hair = Path()
        hair.move(to: CGPoint(x: 0, y: plotH)); hair.addLine(to: CGPoint(x: size.width, y: plotH))
        ctx.stroke(hair, with: .color(.secondary.opacity(0.35)), lineWidth: 0.5)

        let t0 = Double(start) / rate
        let t1 = Double(start + span) / rate
        let visible = max(0.0001, t1 - t0)
        let interval = Self.tickInterval(visibleSeconds: visible, width: size.width)
        let subSecond = interval < 1

        var t = (t0 / interval).rounded(.up) * interval
        while t <= t1 + 1e-9 {
            let x = CGFloat((t - t0) / visible) * size.width

            var grid = Path()
            grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: plotH))
            ctx.stroke(grid, with: .color(.secondary.opacity(0.12)), lineWidth: 0.5)

            var tick = Path()
            tick.move(to: CGPoint(x: x, y: plotH)); tick.addLine(to: CGPoint(x: x, y: plotH + 4))
            ctx.stroke(tick, with: .color(.secondary.opacity(0.5)), lineWidth: 0.5)

            let labelX = min(max(24, x), size.width - 24)
            ctx.draw(Text(Self.timeLabel(t, subSecond: subSecond))
                        .font(.system(size: 9)).foregroundStyle(.secondary),
                     at: CGPoint(x: labelX, y: plotH + 6), anchor: .top)

            t += interval
        }
    }

    nonisolated private static func timeLabel(_ seconds: Double, subSecond: Bool) -> String {
        let s = max(0, seconds)
        let minutes = Int(s) / 60
        let rem = s - Double(minutes * 60)
        return subSecond
            ? String(format: "%d:%05.2f", minutes, rem)
            : String(format: "%d:%02d", minutes, Int(rem.rounded()))
    }
}

/// AppKit view that reports scroll-wheel and mouse-drag events to SwiftUI. Sits on top of the
/// waveform canvas so it can zoom toward the pointer, which SwiftUI has no first-class API for.
private struct InputCatcher: NSViewRepresentable {
    enum Phase { case began, changed, ended }

    var onScroll: (_ deltaX: CGFloat, _ deltaY: CGFloat, _ x: CGFloat) -> Void
    var onDrag: (_ x: CGFloat, _ phase: Phase) -> Void
    var onDoubleClick: (_ x: CGFloat) -> Void
    var edgeNearX: (_ x: CGFloat) -> Bool

    func makeNSView(context: Context) -> NSView {
        let view = CatchingView()
        apply(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let view = nsView as? CatchingView { apply(to: view) }
    }

    private func apply(to view: CatchingView) {
        view.onScroll = onScroll
        view.onDrag = onDrag
        view.onDoubleClick = onDoubleClick
        view.edgeNearX = edgeNearX
    }

    final class CatchingView: NSView {
        var onScroll: ((CGFloat, CGFloat, CGFloat) -> Void)?
        var onDrag: ((CGFloat, Phase) -> Void)?
        var onDoubleClick: ((CGFloat) -> Void)?
        var edgeNearX: ((CGFloat) -> Bool)?
        private var tracking: NSTrackingArea?
        private var dragging = false

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: bounds,
                                      options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                      owner: self, userInfo: nil)
            addTrackingArea(area)
            tracking = area
        }

        override func scrollWheel(with event: NSEvent) {
            onScroll?(event.scrollingDeltaX, event.scrollingDeltaY, localX(event))
        }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { onDoubleClick?(localX(event)) }
            else { dragging = true; onDrag?(localX(event), .began) }
        }

        override func mouseDragged(with event: NSEvent) { onDrag?(localX(event), .changed) }

        override func mouseUp(with event: NSEvent) {
            dragging = false
            onDrag?(localX(event), .ended)
        }

        override func mouseMoved(with event: NSEvent) {
            guard !dragging else { return }
            if edgeNearX?(localX(event)) == true { NSCursor.resizeLeftRight.set() }
            else { NSCursor.arrow.set() }
        }

        override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }

        private func localX(_ event: NSEvent) -> CGFloat {
            convert(event.locationInWindow, from: nil).x
        }

        override var acceptsFirstResponder: Bool { true }
    }
}
