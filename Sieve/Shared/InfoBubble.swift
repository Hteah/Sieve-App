import SwiftUI

/// Shared slot for the "Show Control Info" hint strip: the description of whichever
/// `infoBubble` control the pointer is currently over. Injected by the window that
/// draws the strip; where it's absent, `infoBubble` is just a plain `.help` tooltip.
@MainActor @Observable
final class ControlHint {
    var text: String = ""
}

extension View {
    /// A native `.help` tooltip. While "Show Control Info" is checked in the View menu
    /// and a `ControlHint` is in the environment, hovering also shows `text` in the
    /// window's bottom hint strip. Drop-in for `.help(_:)` on toolbar / header controls.
    func infoBubble(_ text: String) -> some View {
        modifier(InfoBubbleModifier(text: text))
    }
}

private struct InfoBubbleModifier: ViewModifier {
    let text: String
    @Environment(ControlHint.self) private var hint: ControlHint?
    @AppStorage("showControlInfo") private var enabled = false

    func body(content: Content) -> some View {
        content
            .help(text)
            .onHover { inside in
                guard enabled, let hint else { return }
                if inside {
                    hint.text = text
                } else if hint.text == text {
                    hint.text = ""
                }
            }
    }
}
