import Foundation
import GRDB
import Observation
import os

/// Drives the sidebar + table: observes the DB for the current filter and keeps selection.
@MainActor
@Observable
final class LibraryViewModel {
    private let database: AppDatabase
    private static let log = Logger(subsystem: "com.arlo.Sieve", category: "library")

    var filter = SampleFilter() {
        didSet {
            guard filter != oldValue else { return }
            // A pure sort change (field or direction) just reorders the rows already in memory —
            // no need to tear down the observation and re-decode the whole table from SQLite.
            if filter.samePredicate(as: oldValue) {
                sortRowsInPlace()
            } else {
                restartRowsObservation()
            }
        }
    }
    private(set) var rows: [SampleRow] = []
    private(set) var roots: [Root] = []
    private(set) var folderTrees: [Int64: [Queries.FolderNode]] = [:]
    private(set) var tags: [Queries.TagCount] = []
    private(set) var isLoading = false
    var selection = Set<Int64>()

    @ObservationIgnored private var rowsTask: Task<Void, Never>?
    @ObservationIgnored private var sidebarTask: Task<Void, Never>?
    @ObservationIgnored private var searchDebounce: Task<Void, Never>?
    @ObservationIgnored private var sortTask: Task<Void, Never>?

    init(database: AppDatabase) {
        self.database = database
        restartRowsObservation()
        startSidebarObservation()
    }

    var selectedRows: [SampleRow] {
        rows.filter { selection.contains($0.id) }
    }

    var primarySelection: SampleRow? {
        guard let id = selection.first else { return nil }
        return rows.first { $0.id == id }
    }

    /// Debounced search input.
    var searchText: String = "" {
        didSet {
            searchDebounce?.cancel()
            let text = searchText
            searchDebounce = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
                self?.filter.searchText = text
            }
        }
    }

    func root(for id: Int64) -> Root? { roots.first { $0.id == id } }

    /// Reorders the rows already in memory for the current sort — no database round-trip.
    /// Large lists are sorted off the main actor so the direction toggle never blocks the UI.
    private func sortRowsInPlace() {
        let sort = filter.sort
        let ascending = filter.sortAscending
        let source = rows
        sortTask?.cancel()

        guard source.count > 1_000 else {
            rows = source.sorted { sort.rowsAreInOrder($0, $1, ascending: ascending) }
            return
        }
        sortTask = Task { [weak self] in
            let sorted = await Task.detached(priority: .userInitiated) {
                source.sorted { sort.rowsAreInOrder($0, $1, ascending: ascending) }
            }.value
            guard !Task.isCancelled, let self,
                  self.filter.sort == sort, self.filter.sortAscending == ascending else { return }
            self.rows = sorted
        }
    }

    // MARK: Observation

    private func restartRowsObservation() {
        rowsTask?.cancel()
        let request = Queries.request(for: filter)
        isLoading = true
        let observation = ValueObservation.tracking { db in try request.fetchAll(db) }
        rowsTask = Task { [weak self, database] in
            do {
                for try await rows in observation.values(in: database.reader) {
                    guard let self, !Task.isCancelled else { return }
                    self.sortTask?.cancel()
                    self.rows = rows            // already ordered by the query's ORDER BY
                    self.isLoading = false
                    // Drop selection entries that no longer exist.
                    let ids = Set(rows.map(\.id))
                    if !self.selection.isSubset(of: ids) { self.selection.formIntersection(ids) }
                }
            } catch {
                Self.log.error("rows observation failed: \(error, privacy: .public)")
            }
        }
    }

    private func startSidebarObservation() {
        let observation = ValueObservation.tracking { db -> ([Root], [Int64: [Queries.FolderNode]], [Queries.TagCount]) in
            let roots = try Root.order(Column("name").collating(.localizedCaseInsensitiveCompare)).fetchAll(db)
            var trees: [Int64: [Queries.FolderNode]] = [:]
            for r in roots { if let id = r.id { trees[id] = try Queries.folderTree(db: db, rootId: id) } }
            let tags = try Queries.tagCounts(db: db)
            return (roots, trees, tags)
        }
        sidebarTask = Task { [weak self, database] in
            do {
                for try await (roots, trees, tags) in observation.values(in: database.reader) {
                    guard let self else { return }
                    self.roots = roots
                    self.folderTrees = trees
                    self.tags = tags
                }
            } catch {
                Self.log.error("sidebar observation failed: \(error, privacy: .public)")
            }
        }
    }
}
