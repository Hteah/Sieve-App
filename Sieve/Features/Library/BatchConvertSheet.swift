import AppKit
import SwiftUI

/// Batch sample-rate / bit-depth conversion for the rows selected in the list. Rewrites the
/// originals in place (WAV output) after each new file is written and validated.
struct BatchConvertSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: LibraryViewModel
    let rows: [SampleRow]

    @AppStorage("batchConvertSR") private var srRaw = 0
    @AppStorage("batchConvertBits") private var bitsRaw = BitDepthOption.int24.rawValue

    @State private var phase: Phase = .configure
    @State private var progress = Progress(done: 0, total: 0, name: "")
    @State private var results: [ConvertResult] = []
    @State private var cancelRequested = false

    enum Phase { case configure, working, done }
    struct Progress { var done: Int; var total: Int; var name: String }

    private var settings: ConvertSettings {
        ConvertSettings(sampleRate: SampleRateOption(rawValue: srRaw) ?? .keep,
                        bitDepth: BitDepthOption(rawValue: bitsRaw) ?? .int24)
    }

    /// Present files on an available root — the only ones we can rewrite.
    private var eligible: [SampleRow] {
        rows.filter { $0.status == .present && (model.root(for: $0.rootId)?.isAvailable ?? false) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch phase {
            case .configure: configureView
            case .working: workingView
            case .done: doneView
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    // MARK: Configure

    private var configureView: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Convert \(eligible.count) file\(eligible.count == 1 ? "" : "s")").font(.headline)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Sample rate").gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                    Picker("", selection: $srRaw) {
                        ForEach(SampleRateOption.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    .labelsHidden()
                }
                GridRow {
                    Text("Bit depth").gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                    Picker("", selection: $bitsRaw) {
                        ForEach(BitDepthOption.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    .labelsHidden()
                }
                GridRow {
                    Text("Output").gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                    Text("WAV, PCM · channel count unchanged").foregroundStyle(.secondary)
                }
            }

            Label {
                Text("Originals are replaced in place — this can't be undone. Non-WAV files (AIFF, etc.) are converted to WAV and the original is deleted. Ratings, tags and notes are copied to the converted audio.")
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)

            if eligible.count < rows.count {
                Text("\(rows.count - eligible.count) selected file\(rows.count - eligible.count == 1 ? " is" : "s are") missing or on an unavailable volume and will be skipped.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Convert", role: .destructive) { start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(eligible.isEmpty)
            }
        }
    }

    // MARK: Working

    private var workingView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Converting…").font(.headline)
            ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
            Text(progress.name.isEmpty ? " " : progress.name)
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Text("\(progress.done) of \(progress.total)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Stop") { cancelRequested = true }.disabled(cancelRequested)
            }
        }
    }

    // MARK: Done

    private var doneView: some View {
        let converted = results.filter(\.succeeded)
        let failed = results.compactMap { r -> (String, String)? in
            if case .failed(let m) = r.outcome { return (r.filename, m) }
            return nil
        }
        let skipped = results.filter { $0.outcome == .skippedNoOp }.count
        return VStack(alignment: .leading, spacing: 12) {
            Text(summaryLine(converted: converted.count, failed: failed.count, skipped: skipped, stopped: cancelRequested))
                .font(.headline)
            if !failed.isEmpty {
                List(failed, id: \.0) { item in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.0)
                        Text(item.1).font(.caption).foregroundStyle(.red)
                    }
                }
                .frame(minHeight: 100, maxHeight: 220)
            }
            HStack {
                if case .converted(let url, _) = converted.first?.outcome {
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private func summaryLine(converted: Int, failed: Int, skipped: Int, stopped: Bool) -> String {
        var parts = ["\(converted) converted"]
        if failed > 0 { parts.append("\(failed) failed") }
        if skipped > 0 { parts.append("\(skipped) already WAV, unchanged") }
        return (stopped ? "Stopped — " : "") + parts.joined(separator: ", ")
    }

    // MARK: Run

    private func start() {
        let jobs: [ConvertJob] = eligible.compactMap { row in
            guard let url = env.fileURL(for: row) else { return nil }
            return ConvertJob(sampleId: row.id, source: url, oldContentHash: row.contentHash, rootId: row.rootId)
        }
        guard !jobs.isEmpty else { dismiss(); return }
        let byId = Dictionary(uniqueKeysWithValues: eligible.map { ($0.id, $0) })
        let cfg = settings
        phase = .working
        progress = Progress(done: 0, total: jobs.count, name: "")

        Task {
            let rootIds = Set(jobs.map(\.rootId))
            var scoped: [URL] = []
            for id in rootIds {
                if let u = env.rootURL(for: id), u.startAccessingSecurityScopedResource() { scoped.append(u) }
            }
            defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }

            var acc: [ConvertResult] = []
            for (index, job) in jobs.enumerated() {
                if cancelRequested { break }
                progress = Progress(done: index, total: jobs.count, name: job.source.lastPathComponent)
                let result = await Task.detached(priority: .userInitiated) {
                    AudioConverter.convert(job: job, settings: cfg)
                }.value
                acc.append(result)

                if case let .converted(finalURL, newHash) = result.outcome,
                   let oldHash = job.oldContentHash, let newHash, oldHash != newHash,
                   let rootURL = env.rootURL(for: job.rootId) {
                    let rel = relativePath(of: finalURL, under: rootURL)
                        ?? byId[job.sampleId]?.relativePath
                        ?? finalURL.lastPathComponent
                    try? await AnnotationStore(database: env.database)
                        .carryOverAnnotation(from: oldHash, to: newHash, rootId: job.rootId, relativePath: rel)
                }
            }

            progress = Progress(done: acc.count, total: jobs.count, name: "")
            results = acc
            phase = .done
            for id in rootIds { await env.scanner.scan(rootId: id) }
        }
    }

    private func relativePath(of url: URL, under root: URL) -> String? {
        let file = url.standardizedFileURL.path
        var base = root.standardizedFileURL.path
        if !base.hasSuffix("/") { base += "/" }
        guard file.hasPrefix(base) else { return nil }
        return String(file.dropFirst(base.count))
    }
}
