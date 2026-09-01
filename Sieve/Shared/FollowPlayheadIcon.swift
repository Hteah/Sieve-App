import SwiftUI

/// Toolbar glyph for the "follow playhead" toggle: a timeline ruler with a centred playhead
/// and left/right chevrons (the view tracks the playhead). Drawn, not an SF Symbol. Tints
/// with the surrounding `foregroundStyle`.
struct FollowPlayheadIcon: View {
    @ScaledMetric(relativeTo: .body) private var side: CGFloat = 15

    var body: some View {
        Canvas { ctx, s in
            let w = s.width, h = s.height, cx = w / 2
            let rulerY = h * 0.16

            // Ruler with a symmetric comb of tick marks.
            var ruler = Path()
            ruler.move(to: CGPoint(x: w * 0.08, y: rulerY))
            ruler.addLine(to: CGPoint(x: w * 0.92, y: rulerY))
            ctx.stroke(ruler, with: .foreground, lineWidth: 1.4)

            var ticks = Path()
            for off in [0.12, 0.24, 0.36] as [CGFloat] {
                for x in [cx - off * w, cx + off * w] {
                    ticks.move(to: CGPoint(x: x, y: rulerY))
                    ticks.addLine(to: CGPoint(x: x, y: rulerY + h * 0.12))
                }
            }
            ctx.stroke(ticks, with: .foreground, lineWidth: 0.9)

            // Playhead: line down the centre, triangle head just under the ruler.
            var line = Path()
            line.move(to: CGPoint(x: cx, y: rulerY))
            line.addLine(to: CGPoint(x: cx, y: h * 0.88))
            ctx.stroke(line, with: .foreground, lineWidth: 1.2)

            let tw = w * 0.16, ty = rulerY + h * 0.02
            var head = Path()
            head.move(to: CGPoint(x: cx - tw, y: ty))
            head.addLine(to: CGPoint(x: cx + tw, y: ty))
            head.addLine(to: CGPoint(x: cx, y: ty + h * 0.26))
            head.closeSubpath()
            ctx.fill(head, with: .foreground)

            // Follow chevrons, < and >, flanking the playhead line, centred on it vertically.
            let cy = h * 0.60, ch = h * 0.16, reach = w * 0.31
            var chev = Path()
            chev.move(to: CGPoint(x: cx - reach + ch, y: cy - ch))
            chev.addLine(to: CGPoint(x: cx - reach, y: cy))
            chev.addLine(to: CGPoint(x: cx - reach + ch, y: cy + ch))
            chev.move(to: CGPoint(x: cx + reach - ch, y: cy - ch))
            chev.addLine(to: CGPoint(x: cx + reach, y: cy))
            chev.addLine(to: CGPoint(x: cx + reach - ch, y: cy + ch))
            ctx.stroke(chev, with: .foreground,
                       style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
        }
        .frame(width: side, height: side)
        // A Canvas has no text baseline; place one where an SF Symbol of this size sits so the
        // toggle lines up with the plain Image button beside it in the baseline-aligned header.
        .alignmentGuide(.firstTextBaseline) { d in d.height * 0.8 }
        .accessibilityHidden(true)
    }
}
