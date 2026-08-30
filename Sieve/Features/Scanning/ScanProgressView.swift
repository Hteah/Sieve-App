import SwiftUI

struct ScanProgressView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        if env.scanState.isScanning {
            HStack(spacing: 8) {
                if let f = env.scanState.fraction {
                    ProgressView(value: f).frame(width: 120)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(env.scanState.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Button { Task { await env.scanner.cancelAll() } } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).help("Cancel scan")
            }
        }
    }
}
