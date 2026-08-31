import Foundation
import GRDB
import Observation
import SwiftUI
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
            // Kept as a separate observable flag so a sort/search/rating change to `filter`
            // doesn't invalidate ContentView (which only cares whether the duplicates view is up).
            let dup = filter.scope == .duplicates
            if showsDuplicates != dup { showsDuplicates = dup }
            // A pure sort change (field or direction) just reorders the rows already in memory —
            // no need to tear down the observation and re-decode the whole table from SQLite.
            if filter.samePredicate(as: oldValue) {
                sortRowsInPlace()
            } else {
                restartRowsObservation()
            }
        }
    }
    private(set) var showsDuplicates = false
    private(set) var rows: [SampleRow] = []
    private(set) var roots: [Root] = []
    private(set) var groups: [FolderGroup] = []
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
    /// Large lists are sorted off the main actor. The assignment is made without an implicit
    /// animation so the table doesn't choreograph hundreds of row moves.
    private func sortRowsInPlace() {
        let sort = filter.sort
        let ascending = filter.sortAscending
        let source = rows
        sortTask?.cancel()

        guard source.count > 1_000 else {
            let clock = ContinuousClock()
            let start = clock.now
            let sorted = source.sorted { sort.rowsAreInOrder($0, $1, ascending: ascending) }
            let elapsed = clock.now - start
            Self.log.info("sort \(source.count) rows by \(sort.rawValue, privacy: .public) asc=\(ascending): \(elapsed.description, privacy: .public)")
            assignRows(sorted)
            return
        }
        sortTask = Task { [weak self] in
            let sorted = await Task.detached(priority: .userInitiated) {
                source.sorted { sort.rowsAreInOrder($0, $1, ascending: ascending) }
            }.value
            guard !Task.isCancelled, let self,
                  self.filter.sort == sort, self.filter.sortAscending == ascending else { return }
            self.assignRows(sorted)
        }
    }

    private func assignRows(_ newRows: [SampleRow]) {
        var tx = Transaction()
        tx.disablesAnimations = true
        withTransaction(tx) { rows = newRows }
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

    private struct SidebarData: Sendable {
        var roots: [Root]
        var groups: [FolderGroup]
        var trees: [Int64: [Queries.FolderNode]]
        var tags: [Queries.TagCount]
    }

    private func startSidebarObservation() {
        let observation = ValueObservation.tracking { db -> SidebarData in
            let roots = try Root.order(Column("name").collating(.localizedCaseInsensitiveCompare)).fetchAll(db)
            let groups = try FolderGroup
                .order(Column("sortOrder"), Column("name").collating(.localizedCaseInsensitiveCompare))
                .fetchAll(db)
            var trees: [Int64: [Queries.FolderNode]] = [:]
            for r in roots { if let id = r.id { trees[id] = try Queries.folderTree(db: db, rootId: id) } }
            return SidebarData(roots: roots, groups: groups, trees: trees, tags: try Queries.tagCounts(db: db))
        }
        sidebarTask = Task { [weak self, database] in
            do {
                for try await data in observation.values(in: database.reader) {
                    guard let self else { return }
                    self.roots = data.roots
                    self.groups = data.groups
                    self.folderTrees = data.trees
                    self.tags = data.tags
                    // Don't leave a filter pointing at a group that no longer exists.
                    if case .group(let gid) = self.filter.scope,
                       !data.groups.contains(where: { $0.id == gid }) {
                        self.filter.scope = .all
                    }
                }
            } catch {
                Self.log.error("sidebar observation failed: \(error, privacy: .public)")
            }
        }
    }
}
