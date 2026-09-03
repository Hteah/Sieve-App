import AppKit
import GRDB
import SwiftUI

/// Standalone window listing every file operation Sieve has performed — trash, delete, and move,
/// including drag-onto-a-folder moves — newest first, with a one-click Undo for moves.
///
/// Every op is already logged to `file_op_log` by `FileOperator`; this is the view onto it.
struct MoveHistoryView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.palette) private var palette

    @State private var entries: [Entry] = []
    @State private var scope: Scope = .movesOnly
    @State private var selection: Int64?
    @State private var undoing: Set<Int64> = []
    @State private var pendingUndo: Entry?
    @State private var failure: String?

    enum Scope: String, CaseIterable, Identifiable {
        case movesOnly = "Moves"
        case all = "All operations"
        var id: String { rawValue }
    }

    /// A log row with its source root's name resolved and its paths pre-formatted for the table.
    struct Entry: Identifiable, Equatable {
        let log: FileOpLog
        let rootName: String

        var id: Int64 { log.id ?? -1 }

        var action: String {
            switch log.op {
            case "trash": "Trash"
            case "delete": "Delete"
            case "move": "Move"
            case "undo move": "Undo move"
            default: log.op.capitalized
            }
        }

        /// Where the file came from.
        var from: String {
            if log.op == "undo move", let d = log.destinationPath {
                return MoveHistoryView.abbreviate(d)
            }
            return "\(rootName)/\(log.relativePath)"
        }

        /// Where the file ended up.
        var to: String {
            switch log.op {
            case "trash": return "Trash"
            case "delete": return "\u{2014}"
            case "undo move": return "\(rootName)/\(log.relativePath)"
            default: return log.destinationPath.map(MoveHistoryView.abbreviate) ?? "\u{2014}"
            }
        }

        var result: String {
            if !log.succeeded { return log.error ?? "Failed" }
            if log.undoneAt != nil { return "Undone" }
            return "OK"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if entries.isEmpty {
                ContentUnavailableView(
                    scope == .movesOnly ? "No Moves Yet" : "No File Operations Yet",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Moving, trashing or deleting samples records an entry here."))
            } else {
                table
            }
        }
        .frame(minWidth: 720, minHeight: 360)
        .background(palette.surface)
        .task(id: scope) { await observe() }
        .alert("Move this file back?", isPresented: Binding(get: { pendingUndo != nil }, set: { if !$0 { pendingUndo = nil } })) {
            Button("Cancel", role: .cancel) { pendingUndo = nil }
            Button("Undo Move") { if let e = pendingUndo { pendingUndo = nil; runUndo(e) } }
        } message: {
            if let e = pendingUndo {
                Text("\(e.log.relativePath.components(separatedBy: "/").last ?? e.log.relativePath) will be moved from\n\(e.to)\nback to\n\(e.from)")
            }
        }
        .alert("Couldn\u{2019}t Undo", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK") { failure = nil }
        } message: {
            Text(failure ?? "")
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Picker("", selection: $scope) {
                ForEach(Scope.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()

            Spacer()

            if let id = selection, let entry = entries.first(where: { $0.id == id }) {
                undoButton(for: entry)
            }
        }
        .padding(10)
    }

    private var table: some View {
        Table(entries, selection: $selection) {
            TableColumn("When") { e in
                Text(e.log.performedAt.formatted(date: .abbreviated, time: .shortened))
                    .foregroundStyle(.secondary)
            }
            .width(min: 120, ideal: 150)

            TableColumn("Action") { e in
                Label(e.action, systemImage: icon(for: e.log.op))
                    .labelStyle(.titleAndIcon)
            }
            .width(min: 80, ideal: 100)

            TableColumn("File") { e in
                Text(e.log.relativePath.components(separatedBy: "/").last ?? e.log.relativePath)
                    .lineLimit(1).truncationMode(.middle)
            }
            .width(min: 120, ideal: 180)

            TableColumn("From") { e in
                Text(e.from).lineLimit(1).truncationMode(.head)
                    .foregroundStyle(.secondary).help(e.from)
            }
            .width(min: 140, ideal: 240)

            TableColumn("To") { e in
                Text(e.to).lineLimit(1).truncationMode(.head)
                    .foregroundStyle(.secondary).help(e.to)
            }
            .width(min: 140, ideal: 240)

            TableColumn("Result") { e in
                Text(e.result)
                    .lineLimit(1).truncationMode(.tail)
                    .foregroundStyle(e.log.succeeded ? (e.log.undoneAt == nil ? Color.secondary : Color.orange) : Color.red)
                    .help(e.result)
            }
            .width(min: 70, ideal: 120)
        }
        .contextMenu(forSelectionType: Int64.self) { ids in
            if let id = ids.first, let entry = entries.first(where: { $0.id == id }) {
                if entry.log.isUndoableMove {
                    Button("Undo Move") { pendingUndo = entry }
                }
                Button("Reveal Current Location in Finder") { reveal(entry) }
            }
        }
        .tableStyle(.inset)
    }

    @ViewBuilder
    private func undoButton(for entry: Entry) -> some View {
        if undoing.contains(entry.id) {
            ProgressView().controlSize(.small)
        } else {
            Button("Undo Move") { pendingUndo = entry }
                .disabled(!entry.log.isUndoableMove)
                .help(undoHint(for: entry))
        }
    }

    private func undoHint(for entry: Entry) -> String {
        if entry.log.op != "move" { return "Only moves can be undone here." }
        if !entry.log.succeeded { return "This move didn\u{2019}t complete." }
        if entry.log.undoneAt != nil { return "Already undone." }
        return "Move this file back to where it was."
    }

    private func icon(for op: String) -> String {
        switch op {
        case "trash": "trash"
        case "delete": "xmark.bin"
        case "undo move": "arrow.uturn.backward"
        default: "arrow.right.doc.on.clipboard"
        }
    }

    // MARK: Actions

    private func runUndo(_ entry: Entry) {
        guard entry.log.isUndoableMove else { return }
        undoing.insert(entry.id)
        Task {
            let op = FileOperator(database: env.database, bookmarks: env.bookmarks)
            let result = await op.undoMove(entry.log)
            undoing.remove(entry.id)
            if result.succeeded {
                var roots: Set<Int64> = [entry.log.rootId]
                if let dest = entry.log.destinationPath,
                   let destRoot = env.rootId(containing: URL(fileURLWithPath: dest)) {
                    roots.insert(destRoot)
                }
                for id in roots { await env.scanner.scan(rootId: id) }
            } else {
                failure = result.error ?? "The file couldn\u{2019}t be moved back."
            }
        }
    }

    private func reveal(_ entry: Entry) {
        let path: String? = {
            switch entry.log.op {
            case "move" where entry.log.undoneAt == nil: return entry.log.destinationPath
            default:
                guard let root = env.rootURL(for: entry.log.rootId) else { return nil }
                return root.appending(path: entry.log.relativePath).path
            }
        }()
        guard let path, FileManager.default.fileExists(atPath: path) else {
            failure = "That file isn\u{2019}t at its recorded location any more."
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    // MARK: Data

    private func observe() async {
        let onlyMoves = scope == .movesOnly
        let observation = ValueObservation.tracking { db -> [Entry] in
            let names = [Int64: String](
                uniqueKeysWithValues: try Root.fetchAll(db).compactMap { r in r.id.map { ($0, r.name) } })
            let sql = onlyMoves
                ? "SELECT * FROM file_op_log WHERE op IN ('move', 'undo move') ORDER BY performedAt DESC LIMIT 1000"
                : "SELECT * FROM file_op_log ORDER BY performedAt DESC LIMIT 1000"
            return try FileOpLog.fetchAll(db, sql: sql).map { log in
                Entry(log: log, rootName: names[log.rootId] ?? "?")
            }
        }
        do {
            for try await rows in observation.values(in: env.database.reader) {
                entries = rows
            }
        } catch {
            env.report(error)
        }
    }

    /// `/Users/me/Music/Packs/x` → `~/Music/Packs/x` for a tidier table.
    nonisolated static func abbreviate(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}
