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
    /// Called with the clicked frame when the user clicks (not drags) the waveform.
    var onClickSeek: ((Int) -> Void)? = nil
    /// Changes when a different file is loaded; resets the zoom/scroll window.
    var resetToken: AnyHashable?

    @State private var visibleStart = 0
    @State private var visibleFrames = 0          // 0 => whole clip
    @State private var dragAnchor: Int?

    private let minSpan = 16

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
                    onDoubleClick: { _ in if n > 0 { selection = 0..<n } }
                )
            }
            .overlay(alignment: .topTrailing) { zoomControls(width: width, n: n, span: span, start: start) }
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

    private func handleDrag(x: CGFloat, phase: InputCatcher.Phase, width: CGFloat, span: Int, start: Int) {
        let f = frame(atX: x, width: width, span: span, start: start)
        switch phase {
        case .began:
            dragAnchor = f
        case .changed:
            let a = dragAnchor ?? f
            let lo = min(a, f), hi = max(a, f)
            selection = lo < hi ? lo..<hi : nil
        case .ended:
            let framesPerPixel = Double(span) / Double(max(1, width))
            if let a = dragAnchor, abs(a - f) <= max(1, Int(3 * framesPerPixel)) {
                selection = nil          // a click clears the selection…
                onClickSeek?(f)          // …and moves the playhead here
            }
            dragAnchor = nil
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
        let laneHeight = size.height / CGFloat(lanes)
        guard n > 0, size.width >= 1 else {
            var line = Path()
            line.move(to: CGPoint(x: 0, y: size.height / 2))
            line.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            ctx.stroke(line, with: .color(.secondary.opacity(0.3)), lineWidth: 1)
            return
        }
        let columns = Int(size.width.rounded(.up))
        let spp = Double(span) / Double(max(1, columns))
        let level = mip?.level(forSamplesPerPixel: spp)
        let end = min(n, start + span)

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
                } else if c < clip.channels.count {
                    // No pyramid yet (just-loaded / mid-edit): scan raw, but sub-sample when a
                    // column covers a huge span so this stays smooth until the mip lands.
                    let ch = clip.channels[c]
                    let step = max(1, (f1 - f0) / 2048)
                    lo = ch[f0]; hi = ch[f0]
                    var i = f0 + step
                    while i < f1 {
                        let v = ch[i]
                        if v < lo { lo = v }
                        if v > hi { hi = v }
                        i += step
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

        if let s = selection, !s.isEmpty {
            let x0 = max(0, xForFrame(s.lowerBound))
            let x1 = min(size.width, xForFrame(s.upperBound))
            if x1 > 0, x0 < size.width, x1 > x0 {
                ctx.fill(Path(CGRect(x: x0, y: 0, width: max(1, x1 - x0), height: size.height)),
                         with: .color(.accentColor.opacity(0.18)))
            }
            for (f, x) in [(s.lowerBound, xForFrame(s.lowerBound)), (s.upperBound, xForFrame(s.upperBound))]
            where f >= start && f <= end {
                var edge = Path()
                edge.move(to: CGPoint(x: x, y: 0))
                edge.addLine(to: CGPoint(x: x, y: size.height))
                ctx.stroke(edge, with: .color(.accentColor.opacity(0.85)), lineWidth: 1)
            }
        }

        if let f = playheadFrame, f >= start, f <= end {
            let x = xForFrame(f)
            var line = Path()
            line.move(to: CGPoint(x: x, y: 0))
            line.addLine(to: CGPoint(x: x, y: size.height))
            ctx.stroke(line, with: .color(.primary), lineWidth: 1)
        }
    }
}

/// AppKit view that reports scroll-wheel and mouse-drag events to SwiftUI. Sits on top of the
/// waveform canvas so it can zoom toward the pointer, which SwiftUI has no first-class API for.
private struct InputCatcher: NSViewRepresentable {
    enum Phase { case began, changed, ended }

    var onScroll: (_ deltaX: CGFloat, _ deltaY: CGFloat, _ x: CGFloat) -> Void
    var onDrag: (_ x: CGFloat, _ phase: Phase) -> Void
    var onDoubleClick: (_ x: CGFloat) -> Void

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
    }

    final class CatchingView: NSView {
        var onScroll: ((CGFloat, CGFloat, CGFloat) -> Void)?
        var onDrag: ((CGFloat, Phase) -> Void)?
        var onDoubleClick: ((CGFloat) -> Void)?

        override func scrollWheel(with event: NSEvent) {
            onScroll?(event.scrollingDeltaX, event.scrollingDeltaY, localX(event))
        }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { onDoubleClick?(localX(event)) }
            else { onDrag?(localX(event), .began) }
        }

        override func mouseDragged(with event: NSEvent) { onDrag?(localX(event), .changed) }
        override func mouseUp(with event: NSEvent) { onDrag?(localX(event), .ended) }

        private func localX(_ event: NSEvent) -> CGFloat {
            convert(event.locationInWindow, from: nil).x
        }

        override var acceptsFirstResponder: Bool { true }
    }
}
