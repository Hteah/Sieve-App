import SwiftUI

extension View {
    /// A native `.help` tooltip, plus — while "Show Control Info" is checked in the View menu
    /// — a small floating caption on hover. Drop-in for `.help(_:)` on toolbar / header
    /// controls. The caption is an in-window overlay (not a popover), so it never steals the
    /// first click from the control beneath it. `align` biases it toward a window edge:
    /// use `.leading` / `.trailing` for controls hard against the edge so it doesn't clip.
    func infoBubble(_ text: String, align: HorizontalAlignment = .center) -> some View {
        modifier(InfoBubbleModifier(text: text, align: align))
    }
}

private struct InfoBubbleModifier: ViewModifier {
    let text: String
    let align: HorizontalAlignment
    @AppStorage("showControlInfo") private var enabled = false
    @State private var hovering = false
    @State private var armed = false          // hovered past the delay

    private var overlayAlignment: Alignment {
        if align == .leading { return .bottomLeading }
        if align == .trailing { return .bottomTrailing }
        return .bottom
    }

    func body(content: Content) -> some View {
        content
            .help(text)
            .onHover { inside in
                hovering = inside
                if inside {
                    Task {
                        try? await Task.sleep(for: .milliseconds(220))
                        if hovering { armed = true }
                    }
                } else {
                    armed = false
                }
            }
            .overlay(alignment: overlayAlignment) {
                if enabled && hovering && armed {
                    Text(text)
                        .font(.caption)
                        .fixedSize()
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator, lineWidth: 0.5))
                        .shadow(radius: 6, y: 2)
                        .alignmentGuide(VerticalAlignment.bottom) { $0[.top] }
                        .offset(y: 6)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                        .zIndex(1)
                }
            }
            .animation(.easeOut(duration: 0.1), value: armed)
    }
}
