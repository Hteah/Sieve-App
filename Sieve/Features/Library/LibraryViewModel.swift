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

    /// How many rows the list loads at a time. A scope with thousands of samples (e.g. "All")
    /// only ever hands the `Table` this many rows at once — see the pagination comment on
    /// `restartRowsObservation`. 500 is comfortably inside the range the table's sort-column
    /// full-rebuild (`SampleListView`'s `.id(sortToken)`) was already proven fine at (~800).
    private static let pageSize = 500

    var filter = SampleFilter() {
        didSet {
            guard filter != oldValue else { return }
            // Kept as a separate observable flag so a sort/search/rating change to `filter`
            // doesn't invalidate ContentView (which only cares whether the duplicates view is up).
            let dup = filter.scope == .duplicates
            if showsDuplicates != dup { showsDuplicates = dup }
            // Sort changes used to just reorder the rows already in memory, but that meant a
            // library-wide scope handed its *entire* row set to the table to re-sort and
            // re-render — fine at a few hundred rows, but a 15k+ sample library pegged the CPU
            // and beachballed on a single column-header click. Every filter change — sort
            // included — now re-queries SQL (which sorts cheaply regardless of table size) and
            // resets to the first page, so the table never has to rebuild more than `pageSize`
            // rows at once, no matter how large the scope is.
            restartRowsObservation(resetPage: true)
            if !filter.samePredicate(as: oldValue) {
                restartCountObservation()
            }
        }
    }
    private(set) var showsDuplicates = false
    private(set) var rows: [SampleRow] = []
    /// True count of the current scope (ignores pagination) — shown in the status bar since
    /// `rows.count` is now just the loaded window, not the whole scope.
    private(set) var totalCount = 0
    /// Whether more rows exist beyond the currently loaded window.
    private(set) var hasMoreRows = false
    private(set) var roots: [Root] = []
    private(set) var groups: [FolderGroup] = []
    private(set) var folderTrees: [Int64: [Queries.FolderNode]] = [:]
    private(set) var tags: [Queries.TagCount] = []
    private(set) var quickTagCounts: [Int] = Array(repeating: 0, count: QuickTags.count)
    private(set) var isLoading = false
    var selection = Set<Int64>()

    @ObservationIgnored private var rowsTask: Task<Void, Never>?
    @ObservationIgnored private var countTask: Task<Void, Never>?
    @ObservationIgnored private var sidebarTask: Task<Void, Never>?
    @ObservationIgnored private var searchDebounce: Task<Void, Never>?
    @ObservationIgnored private var pageLimit = LibraryViewModel.pageSize

    init(database: AppDatabase) {
        self.database = database
        restartRowsObservation(resetPage: true)
        restartCountObservation()
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

    /// Called as rows scroll into view; grows the loaded window once the trailing edge of what's
    /// already loaded comes on screen. A no-op while more rows can't exist, or a load is already
    /// in flight (rapid scrolling would otherwise fire this many times over before the first
    /// requery lands).
    func loadMoreIfNeeded(near row: SampleRow) {
        guard hasMoreRows, !isLoading,
              let idx = rows.firstIndex(where: { $0.id == row.id }),
              idx >= rows.count - 20 else { return }
        pageLimit += Self.pageSize
        restartRowsObservation(resetPage: false)
    }

    // MARK: Observation

    /// (Re)starts the rows observation for the current filter, bounded to `pageLimit` rows.
    /// `resetPage: true` (any predicate or sort change) snaps back to the first page; `false`
    /// (scrolling near the loaded edge, via `loadMoreIfNeeded`) keeps growing it. Re-querying
    /// SQL with a bigger LIMIT is cheap even for a huge scope — the actual reason this is bounded
    /// at all is the `Table` rendering the result, not the database read.
    private func restartRowsObservation(resetPage: Bool) {
        rowsTask?.cancel()
        if resetPage { pageLimit = Self.pageSize }
        let limit = pageLimit
        let request = Queries.request(for: filter, limit: limit)
        isLoading = true
        let observation = ValueObservation.tracking { db in try request.fetchAll(db) }
        rowsTask = Task { [weak self, database] in
            do {
                for try await rows in observation.values(in: database.reader) {
                    guard let self, !Task.isCancelled else { return }
                    self.rows = rows            // already ordered by the query's ORDER BY
                    self.hasMoreRows = rows.count == limit
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

    /// Tracks the current scope's true row count, independent of the loaded page — shown in the
    /// list's status bar since `rows.count` is only ever the loaded window.
    private func restartCountObservation() {
        countTask?.cancel()
        let request = Queries.countRequest(for: filter)
        let observation = ValueObservation.tracking { db in try request.fetchOne(db) ?? 0 }
        countTask = Task { [weak self, database] in
            do {
                for try await count in observation.values(in: database.reader) {
                    guard let self, !Task.isCancelled else { return }
                    self.totalCount = count
                }
            } catch {
                Self.log.error("count observation failed: \(error, privacy: .public)")
            }
        }
    }

    private struct SidebarData: Sendable {
        var roots: [Root]
        var groups: [FolderGroup]
        var trees: [Int64: [Queries.FolderNode]]
        var tags: [Queries.TagCount]
        var quickTagCounts: [Int]
    }

    private func startSidebarObservation() {
        let observation = ValueObservation.tracking { db -> SidebarData in
            let roots = try Root.order(Column("name").collating(.localizedCaseInsensitiveCompare)).fetchAll(db)
            let groups = try FolderGroup
                .order(Column("sortOrder"), Column("name").collating(.localizedCaseInsensitiveCompare))
                .fetchAll(db)
            var trees: [Int64: [Queries.FolderNode]] = [:]
            for r in roots { if let id = r.id { trees[id] = try Queries.folderTree(db: db, rootId: id) } }
            return SidebarData(roots: roots, groups: groups, trees: trees,
                               tags: try Queries.tagCounts(db: db),
                               quickTagCounts: try Queries.quickTagCounts(db: db))
        }
        sidebarTask = Task { [weak self, database] in
            do {
                for try await data in observation.values(in: database.reader) {
                    guard let self else { return }
                    self.roots = data.roots
                    self.groups = data.groups
                    self.folderTrees = data.trees
                    self.tags = data.tags
                    self.quickTagCounts = data.quickTagCounts
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
