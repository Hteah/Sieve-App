import SwiftUI

extension View {
    /// A native `.help` tooltip, plus — while "Show Control Info" is checked in the View menu
    /// — a small floating caption on hover. Drop-in for `.help(_:)` on toolbar / header
    /// controls. Rendered as a popover so it always stays on screen, even for edge buttons.
    func infoBubble(_ text: String) -> some View {
        modifier(InfoBubbleModifier(text: text))
    }
}

private struct InfoBubbleModifier: ViewModifier {
    let text: String
    @AppStorage("showControlInfo") private var enabled = false
    @State private var hovering = false
    @State private var armed = false          // hovered past the delay

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
            .popover(
                isPresented: Binding(
                    get: { enabled && hovering && armed },
                    set: { if !$0 { armed = false } }
                ),
                arrowEdge: .bottom
            ) {
                Text(text)
                    .font(.caption)
                    .fixedSize()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }
    }
}
