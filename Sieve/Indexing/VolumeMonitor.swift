import AppKit
import Foundation

/// Fires `onChange` when a volume mounts or unmounts so roots can re-check availability.
@MainActor
final class VolumeMonitor {
    var onChange: (@MainActor () -> Void)?
    private var tokens: [any NSObjectProtocol] = []

    init() {
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            let token = nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onChange?() }
            }
            tokens.append(token)
        }
    }

    func stop() {
        let nc = NSWorkspace.shared.notificationCenter
        for t in tokens { nc.removeObserver(t) }
        tokens.removeAll()
    }
}
