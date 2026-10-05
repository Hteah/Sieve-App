import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// AppKit drag-out for sample rows: puts each original file on the drag pasteboard as a plain
/// `NSURL` and offers only `.copy`.
///
/// Not SwiftUI's `.draggable` / Transferable. A FileRepresentation is a file promise that SwiftUI
/// resolves by first copying the file into the container's Caches/com.apple.SwiftUI.Drag-* (never
/// cleaned up — it reached 17 GB), and that copy's path is what lands in `public.file-url`, the
/// first thing JUCE / plain AppKit drop targets read. So R3WRK opened (and ⌘S saved over) a hidden
/// copy, not the library file. `allowAccessingOriginalFile: true`, or a DataRepresentation for
/// `.fileURL`, just left `public.file-url` empty and R3WRK's drop found nothing.
///
/// `.copy` only: Finder copies, it never moves a library file out from under Sieve. Sieve's own
/// drop targets (`SampleDropCatcher`) read the sample ids off `draggedIds` instead of the
/// pasteboard, then decide copy/move themselves.
@MainActor
final class SampleDragSource: NSObject, NSDraggingSource {
    static let shared = SampleDragSource()

    /// Sample ids of the drag in flight (empty when none).
    private(set) var draggedIds: [Int64] = []
    private var scopedRoots: [URL] = []

    struct Item {
        let id: Int64
        let fileURL: URL
        let rootURL: URL?
    }

    /// Starts the drag from the current `leftMouseDragged` event. Call from a gesture's onChanged.
    func begin(_ items: [Item]) {
        guard !items.isEmpty, let event = NSApp.currentEvent, event.type == .leftMouseDragged,
              let view = event.window?.contentView else { return }
        end()
        draggedIds = items.map(\.id)
        // Keep the roots readable for the life of the drag, for sandboxed receivers.
        for root in Set(items.compactMap(\.rootURL)) where root.startAccessingSecurityScopedResource() {
            scopedRoots.append(root)
        }
        let at = view.convert(event.locationInWindow, from: nil)
        let icon = NSWorkspace.shared.icon(for: .audio)
        let dragItems = items.enumerated().map { i, item in
            let d = NSDraggingItem(pasteboardWriter: item.fileURL as NSURL)
            let offset = CGFloat(min(i, 4)) * 4
            d.setDraggingFrame(NSRect(x: at.x - 16 + offset, y: at.y - 16 - offset, width: 32, height: 32),
                               contents: icon)
            return d
        }
        view.beginDraggingSession(with: dragItems, event: event, source: self)
    }

    private func end() {
        draggedIds = []
        scopedRoots.forEach { $0.stopAccessingSecurityScopedResource() }
        scopedRoots = []
    }

    nonisolated func draggingSession(_ session: NSDraggingSession,
                                     sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    nonisolated func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint,
                                     operation: NSDragOperation) {
        MainActor.assumeIsolated { end() }
    }
}

extension View {
    /// Drags `items()` out with `SampleDragSource` once the pointer moves a few points. Simultaneous,
    /// so the cell's own click / seek gestures still run.
    func sampleDragSource(_ items: @escaping () -> [SampleDragSource.Item]) -> some View {
        modifier(SampleDragSourceModifier(items: items))
    }
}

private struct SampleDragSourceModifier: ViewModifier {
    let items: () -> [SampleDragSource.Item]
    @GestureState private var started = false

    func body(content: Content) -> some View {
        content.simultaneousGesture(
            DragGesture(minimumDistance: 6)
                .updating($started) { _, started, _ in
                    guard !started else { return }
                    started = true
                    SampleDragSource.shared.begin(items())
                }
        )
    }
}
