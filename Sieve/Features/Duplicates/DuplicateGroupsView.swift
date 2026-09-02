import AppKit
import GRDB
import SwiftUI

struct DuplicateGroupsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.palette) private var palette
    @Bindable var model: LibraryViewModel

    @State private var groups: [DuplicateGroup] = []
    @State private var keepers: [String: Int64] = [:]
    @State private var pending: PendingOp?
    @State private var results: [FileOpResult]?
    @State private var lastOp: FileOperation?
    @State private var isWorking = false
    @State private var showLog = false

    struct PendingOp: Identifiable {
        let id = UUID()
        var op: FileOperation
        var samples: [SampleRow]
    }

    private var totalWasted: Int64 { groups.reduce(0) { $0 + $1.wastedBytes } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if groups.isEmpty {
                ContentUnavailableView("No Duplicates", systemImage: "doc.on.doc",
                                       description: Text("No two indexed files share identical audio."))
            } else {
                List {
                    ForEach(groups) { group in
                        Section {
                            ForEach(group.members) { member in memberRow(member, in: group) }
                        } header: {
                            groupHeader(group)
                        }
                    }
                }
                .listStyle(.inset)
                .themedSurface(palette)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.surface)
        .task { await observe() }
        .sheet(item: $pending) { p in confirmSheet(p) }
        .sheet(isPresented: Binding(get: { results != nil }, set: { if !$0 { results = nil } })) { resultsSheet }
        .sheet(isPresented: $showLog) { FileOpLogView() }
        .overlay { if isWorking { ProgressView("Working…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8)) } }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading) {
                Text("\(groups.count) duplicate group\(groups.count == 1 ? "" : "s")").font(.headline)
                Text("\(Fmt.bytes(totalWasted)) in redundant copies").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Recent Operations…") { showLog = true }.controlSize(.small)
            Menu("All Groups") {
                Button("Trash All Redundant Copies…") { stage(.trash, samples: allRedundant()) }
                Button("Move All Redundant Copies To…") { chooseDestination { stage(.move(destination: $0), samples: allRedundant()) } }
            }
            .frame(width: 120)
            .disabled(groups.isEmpty)
        }
        .padding(10)
    }

    private func groupHeader(_ group: DuplicateGroup) -> some View {
        HStack {
            Text("\(group.members.count) copies · \(Fmt.duration(group.members.first?.durationSec)) · \(Fmt.bytes(group.wastedBytes)) redundant")
            Spacer()
            Button("Trash Redundant") { stage(.trash, samples: redundant(in: group)) }
            Button("Move Redundant To…") { chooseDestination { stage(.move(destination: $0), samples: redundant(in: group)) } }
        }
        .controlSize(.small)
        .textCase(nil)
    }

    private func memberRow(_ member: SampleRow, in group: DuplicateGroup) -> some View {
        let keeperId = keeper(for: group)
        let rootName = model.root(for: member.rootId)?.name ?? "?"
        let available = model.root(for: member.rootId)?.isAvailable ?? false
        return HStack(spacing: 10) {
            Button {
                keepers[group.hash] = member.id
            } label: {
                Image(systemName: member.id == keeperId ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(member.id == keeperId ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(member.id == keeperId ? "This copy is kept" : "Keep this copy instead")
            WaveformView(summary: member.waveform.flatMap(WaveformSummary.init(encoded:)))
                .frame(width: 90, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(member.filename)
                Text("\(rootName) / \(member.parentDir)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if !available { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).help("Volume not mounted") }
            Text(member.modifiedAt.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary)
            Text(member.id == keeperId ? "Keep" : "Redundant").font(.caption)
                .foregroundStyle(member.id == keeperId ? Color.accentColor : Color.secondary)
                .frame(width: 70, alignment: .trailing)
        }
        .contentShape(Rectangle())
        .onTapGesture { model.selection = [member.id] }
        .onTapGesture(count: 2) { env.preview(member) }
        .contextMenu {
            Button("Play") { env.preview(member) }
            Button("Reveal in Finder") { env.revealInFinder(member) }
            Button("Keep This Copy") { keepers[group.hash] = member.id }
        }
        .listRowBackground(model.selection.contains(member.id) ? Color.accentColor.opacity(0.15) : nil)
    }

    // MARK: Keep logic

    private func keeper(for group: DuplicateGroup) -> Int64? {
        if let k = keepers[group.hash], group.members.contains(where: { $0.id == k }) { return k }
        return group.defaultKeeper?.id
    }

    private func redundant(in group: DuplicateGroup) -> [SampleRow] {
        let k = keeper(for: group)
        return group.members.filter { $0.id != k && (model.root(for: $0.rootId)?.isAvailable ?? false) }
    }

    private func allRedundant() -> [SampleRow] { groups.flatMap(redundant(in:)) }

    // MARK: Ops

    private func stage(_ op: FileOperation, samples: [SampleRow]) {
        guard !samples.isEmpty else { return }
        pending = PendingOp(op: op, samples: samples)
    }

    private func chooseDestination(_ then: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Move Here"
        panel.message = "Choose where to move the redundant copies."
        if let last = env.bookmarks.lastMoveDestination() { panel.directoryURL = last }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        env.bookmarks.rememberMoveDestination(url)
        then(url)
    }

    private func run(_ op: FileOperation, on samples: [SampleRow]) {
        isWorking = true
        lastOp = op
        Task {
            let operator_ = FileOperator(database: env.database, bookmarks: env.bookmarks)
            let r = await operator_.perform(op, on: samples)
            isWorking = false
            results = r
            // Reconcile with disk for the affected roots.
            for rootId in Set(samples.map(\.rootId)) { await env.scanner.scan(rootId: rootId) }
        }
    }

    private func confirmSheet(_ p: PendingOp) -> some View {
        let total = p.samples.reduce(0) { $0 + $1.fileSize }
        let verb: String
        switch p.op {
        case .trash: verb = "Move to Trash"
        case .deletePermanently: verb = "Delete Permanently"
        case .move(let d): verb = "Move to \"\(d.lastPathComponent)\""
        }
        return VStack(alignment: .leading, spacing: 12) {
            Text("\(verb): \(p.samples.count) file\(p.samples.count == 1 ? "" : "s") (\(Fmt.bytes(total)))").font(.headline)
            List(p.samples) { s in
                HStack {
                    Text(s.filename)
                    Spacer()
                    Text("\(model.root(for: s.rootId)?.name ?? "") / \(s.parentDir)").foregroundStyle(.secondary).font(.caption)
                }
            }
            .frame(minHeight: 160, maxHeight: 320)
            if case .deletePermanently = p.op {
                Label("This cannot be undone.", systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            } else if case .trash = p.op {
                Text("Files go to the Trash; use Finder's Put Back to undo.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { pending = nil }.keyboardShortcut(.cancelAction)
                Button(verb, role: p.op == .trash || p.op == .deletePermanently ? .destructive : nil) {
                    pending = nil
                    run(p.op, on: p.samples)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private var resultsSheet: some View {
        let r = results ?? []
        let failed = r.filter { !$0.succeeded }
        return VStack(alignment: .leading, spacing: 12) {
            Text(failed.isEmpty ? "Done: \(r.count) file\(r.count == 1 ? "" : "s") processed" : "\(r.count - failed.count) succeeded, \(failed.count) failed").font(.headline)
            if !failed.isEmpty {
                List(failed) { f in
                    VStack(alignment: .leading) {
                        Text(f.filename)
                        Text(f.error ?? "").font(.caption).foregroundStyle(.red)
                    }
                }
                .frame(minHeight: 120, maxHeight: 260)
                if lastOp == .trash {
                    Text("Trash can fail on some external volumes. You can delete these copies permanently instead.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Spacer()
                if lastOp == .trash, !failed.isEmpty {
                    Button("Delete Permanently…", role: .destructive) {
                        let ids = Set(failed.map(\.sampleId))
                        let samples = groups.flatMap(\.members).filter { ids.contains($0.id) }
                        results = nil
                        stage(.deletePermanently, samples: samples)
                    }
                }
                Button("OK") { results = nil }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func observe() async {
        let observation = ValueObservation.tracking { db in try DuplicateFinder.groups(db: db) }
        do {
            for try await g in observation.values(in: env.database.reader) { groups = g }
        } catch {
            env.report(error)
        }
    }
}

struct FileOpLogView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [FileOpLog] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recent File Operations").font(.headline)
            Table(entries) {
                TableColumn("When") { e in Text(e.performedAt.formatted(date: .abbreviated, time: .shortened)) }.width(140)
                TableColumn("Op") { e in Text(e.op) }.width(50)
                TableColumn("File") { e in Text(e.relativePath) }
                TableColumn("Destination") { e in Text(e.destinationPath ?? "") }
                TableColumn("Result") { e in
                    Text(e.succeeded ? "ok" : (e.error ?? "failed")).foregroundStyle(e.succeeded ? Color.secondary : Color.red)
                }.width(160)
            }
            HStack { Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(20)
        .frame(width: 760, height: 420)
        .task {
            entries = (try? await env.database.reader.read { db in
                try FileOpLog.order(Column("performedAt").desc).limit(500).fetchAll(db)
            }) ?? []
        }
    }
}
