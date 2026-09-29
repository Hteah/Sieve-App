# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Sieve is a native SwiftUI macOS app (macOS 26, Swift 6 strict concurrency) that indexes a music producer's
sample folders, shows amplitude-accurate waveforms, lets the user tag/rate/quick-tag/annotate samples, edit
audio, and find exact duplicates. Indexing never touches files on disk; every write is an explicit user action
(see **Code paths that modify files** below).

Main window: sidebar (Library scopes, folder groups → roots → sub-folder tree, External Drives → roots, Tags, Quick Tags) · sample
`Table` with a filter bar and a status bar ("N samples", "· N selected") · `.inspector` (info + Edit tab).
Other windows (`App/SieveApp.swift`): pop-out Audio Editor, Move History, Theme, Quick Tags.

## Build, test, run

The `.xcodeproj` is generated and gitignored — never edit it; edit `project.yml` and **always run
`xcodegen generate` first** (a fresh checkout, or any added/removed file, otherwise fails with "cannot find X
in scope").

```bash
xcodegen generate
# Debug build (signs with the real identity if Signing.local.xcconfig exists)
xcodebuild -project Sieve.xcodeproj -scheme Sieve -destination 'platform=macOS' -derivedDataPath build build
# Tests — run UNSIGNED in their own derived-data dir. A signed `test` fails to load the test bundle
# ("different Team IDs") / fails codesigning the injected XCTest frameworks.
xcodebuild -project Sieve.xcodeproj -scheme Sieve -destination 'platform=macOS' -derivedDataPath build-test \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO test
# single test (swift-testing): add  -only-testing:SieveTests/FileOperatorTests/moveInsideRootRepathsAndHandlesCollisions
```

- xcodebuild output is very noisy; filter with `grep -E " error:|BUILD"`. **The final "TEST FAILED" banner
  is unreliable** (it appears even when every test passed) — read the result bundle instead:
  `xcrun xcresulttool get test-results summary --path "$(ls -td build-test/Logs/Test/*.xcresult | head -1)"`
  (`result`, `passedTests`, `failedTests`, `testFailures`).
- **Release / install** — a plain universal Release build fails (`Float16` errors on x86_64 in
  `WaveformSummary.swift`), so build the active arch only, then replace the installed app:
  ```bash
  xcodebuild -project Sieve.xcodeproj -scheme Sieve -destination 'platform=macOS' -configuration Release \
    -derivedDataPath build-release ENABLE_PREVIEWS=NO ONLY_ACTIVE_ARCH=YES build
  pkill -x Sieve; sleep 2; ditto build-release/Build/Products/Release/Sieve.app /Applications/Sieve.app
  open /Applications/Sieve.app; ps -o pid,lstart -p $(pgrep -x Sieve)   # confirm it's a fresh process
  ```
  Always kill before `open` — `open` on a running app only activates the stale instance. The user normally
  runs `/Applications/Sieve.app`.
- **Signing:** `Signing.xcconfig` defaults to ad-hoc; the untracked `Signing.local.xcconfig` switches to a real
  Apple Development identity so security-scoped bookmarks survive rebuilds. Background codesign works.

Debug builds honour `SIEVE_ADD_ROOT=/path` (see `AppEnvironment.init`) to register a root at launch without the
folder picker; the path must be sandbox-readable, e.g. inside `~/Library/Containers/com.arlo.Sieve/Data/Documents/`.

**Verifying UI:** launch and screenshot the window —
`screencapture -x -l <CGWindowNumber> out.png`, getting the number from `CGWindowListCopyWindowInfo` (owner
"Sieve", layer 0), e.g. via `swift -e`. `osascript`/System Events has no accessibility permission here, so
clicks/menus can't be driven — say so when a change is untested by hand. When a layout bug isn't obvious, a
temporary `.background(Color.red)` build + screenshot settles it fast. Reserve the test suite for logic
(indexing, hashing, queries, file ops).

**Data:** the library DB is
`~/Library/Containers/com.arlo.Sieve/Data/Library/Application Support/Sieve/library.sqlite` (sandboxed; a
`~/Library/Application Support/Sieve/` copy outside the container is stale — ignore it). To inspect it, copy
`library.sqlite` **plus its `-wal`/`-shm`** somewhere and open the copy read-only. `DEBUG` builds set
`eraseDatabaseOnSchemaChange`, so editing an existing migration wipes the local DB.

**Workflow:** make changes on a branch (the user says when to merge/push; `main` fast-forwards). Old
`.claude/worktrees/*` checkouts exist but active work happens in the main checkout.

## Architecture

**Composition root:** `App/AppEnvironment` (`@MainActor @Observable`) owns `AppDatabase`, `BookmarkStore`,
`ScanCoordinator`, `PreviewPlayer`, `VolumeMonitor`, `EditorSession` (`env.editor`), `WaveformCache`, and is
injected via `.environment(env)`. `LibraryViewModel` is created by `ContentView` and drives sidebar + table.

**Persistence (GRDB, only dependency):** schema in `Persistence/AppDatabase.swift` (`migrator`: `v1`,
`v2-folder-groups`, `v3-quick-tags`, `v4-file-op-undo`, `v5-created-at`, `v6-sort-indexes`). Key tables: `root`
(security-scoped bookmark per user-added folder; `groupId` → `folder_group`), `folder_group`, `sample` (one row
per file; `status` is `present | missing | unavailable`), `sample_fts` (FTS5, synced by triggers), `tag`,
`annotation` (rating, favourite, notes, `quickTags` 6-bit mask), `annotation_tag`, `file_op_log` (every
trash/delete/move/copy; `undoneAt` for Move History undo). The SQL view `sample_with_annotation` is what the UI
reads (`SampleRow`).

**Annotations are keyed by content hash, not path.** `annotation.contentHash` = `sample.audioHash ?? fileHash`,
so ratings/tags/notes survive moves/renames and are shared by identical copies (`Queries.annotation(db:for:create:)`
is the single lookup/create point). Path-keyed fallback exists only for undecodable files.

**Library query (`Persistence/Queries.swift`):** `LibraryScope` (all, favorites, missing, duplicates,
`folderDuplicates(rootId:parentDir:)`, root, folder, group, drive, tag, quickTag) + `SampleFilter` → SQL. The table is
**paginated** (`LibraryViewModel.pageSize` 500, grows on scroll; `totalCount` is the real scope size) — never
hand SwiftUI's `Table` a whole 15k-row scope, and every sort change re-queries SQL. `SampleSort` holds both the
SQL order and the in-memory `rowsAreInOrder`; a sortable column needs a distinct `SampleRow.*SortKey` key path
mapped in `SampleListView.sortComparators`. `Queries.folderPredicate` = "this folder + sub-folders". The
sidebar folder tree (`Queries.folderTree`) is built from distinct `sample.parentDir`s, so a folder with no
indexed samples doesn't appear.

**Scan pipeline (`Indexing/ScanCoordinator`, an actor, one Task per root):** resolve bookmark → reachability check
(unreachable ⇒ mark root + samples `unavailable`, never delete) → `FileEnumerator` → `IncrementalScanner.diff`
(pure, tested; 1 s mtime tolerance) → batched writes → enrichment of rows where `indexedAt IS NULL` in a bounded
`TaskGroup`. Progress: `progressStream()` → `AppEnvironment.scanState`.

**Enrichment is one pass per file** (`Audio/AudioAnalyzer.analyze`): `AVAudioFile` → Float32 → metadata +
SHA-256 over PCM (`audioHash`; container-independent) + `WaveformSummary` (512 buckets × per-channel peak & RMS,
Float16 in `sample.waveform`) + peak/RMS dBFS + clipped-sample count. Undecodable ⇒ only a whole-file `fileHash`.

**Duplicates (`Duplicates/DuplicateFinder`, `Features/Duplicates/DuplicateGroupsView`):** groups present
samples by content hash. `groups(db:in:)` takes an optional folder `Scope` ("Find Duplicates" on a sidebar
folder): copies all inside the folder, or with `includeElsewhere` any group touching it. Rows preview on click
like the list.

**Editor (`Features/Inspector/EditorSession` + `Audio/AudioClip`, `AudioEditorPlayer`):** in-memory edits, then
Save As New / replace in place. It follows the list selection (`ContentView` `.onChange(of: primarySelection)`);
with unsaved edits it asks "Discard unsaved edits?" instead of switching. The Record button
(`Audio/AudioRecorder`) streams the editor's playback to a new 24-bit WAV.

**Code paths that modify files** (all hold the root's security scope):
- `FileOperator` (`Duplicates/FileOperations.swift`) — trash / delete permanently / move / copy of indexed
  samples, used by Duplicates, the list's row menu (⌘⌫ etc.), Move to Folder, drops onto sidebar folders or a
  folder-scoped list, and **Flatten Folder** (`flatten(rootId:parentDir:)`: moves every file out of the
  sub-folders into the folder, then trashes only sub-folders left empty — it must never delete a file).
  Re-verifies size/mtime before acting, logs to `file_op_log`, re-paths rows (or deletes rows for trash/delete,
  marks `missing` if moved outside every root). Filesystem calls go through `FileSystemOps` so tests fake the
  Trash; name clashes get `name (2).ext` (`uniqueDestination`). `undoMove` backs Move History.
- `FinderImport` (same file) — Finder → Sieve drops (Copy default / Move), then rescan.
- `AudioConverter` (batch convert) and editor saves via `Audio/AudioFileIO` (temp → validate → atomic replace;
  a non-WAV source becomes a sibling `.wav`). New audio ⇒ new content hash, so callers use
  `AnnotationStore.carryOverAnnotation` and rescan.

**Sandbox rules:** all file access to a root goes through its bookmark; hold the scope on the *root* URL
(`withSecurityScope` in `BookmarkStore.swift`) — child URLs only inherit while the root's scope is active.
`AppEnvironment.rootURL(for:)` caches resolved root URLs.

**External drives:** `Indexing/DriveInfo` decides "external" from a root's `lastResolvedPath` alone (under
`/Volumes/<name>/`), so it works while the drive is unplugged — no stored column. Ungrouped external roots show
under their drive in the sidebar's External Drives section (grouped ones stay in their group); `.drive(name)` is
every root on that drive. Eject (`AppEnvironment.ejectDrive(named:)`) stops playback from the drive, refuses
while the editor holds unsaved edits to a file on it, then `unmountAndEjectDevice`; `VolumeMonitor` does the rest.
Not drives: the startup disk's own `/Volumes/<boot name>` link and `com.apple.*` volumes (Time Machine
snapshots etc.). Eject from inside the sandbox is untested on real hardware as of 2026-09-29.

**Themes / Quick Tags:** `App/SharedTheme` reads/writes the theme format shared with R3WRK in
`~/Library/Application Support/Shared Themes/` (entitlement in `project.yml`); views use `@Environment(\.palette)`.
Quick Tag slot names/icons live in `UserDefaults` (`App/QuickTags`).

**Concurrency conventions:** `SWIFT_DEFAULT_ACTOR_ISOLATION` is `nonisolated`. AVFoundation objects never cross
isolation boundaries — create and consume them in one actor/task and emit value types. GRDB records are
`Sendable` structs. UI-facing state is `@MainActor @Observable`.

## SwiftUI gotchas hit in this codebase

- **Drag container:** the list uses `.dragContainer(for: SampleDrag.self)` + `.draggable(containerItemID:)`
  (multi-item drag to Finder). Any view inside a `draggable(containerItemID:)` cell must **not** read
  `@Environment(AppEnvironment.self)` — the drag image is rendered outside the window environment and asserts
  ("No Observable object"). Pass `env` in explicitly (see `WaveformCell`).
- **Bottom `.safeAreaInset` on the `NavigationSplitView` is ignored by its scroll views** — content runs
  underneath it. The control-info hint strip is therefore stacked in a `VStack` below the split view.
- `.onTapGesture` followed by `.onTapGesture(count: 2)` — the single tap swallows the double; don't rely on it.
- `SampleListView.body` / `sampleTable` sit near the Swift type-checker budget; pull new pieces into
  separate properties/functions rather than growing the modifier chain.
- A keyboard shortcut only on a context-menu `Button` doesn't fire globally — use `.onKeyPress` on the focused view.

## Adding a column

Update the record struct, **add a new migration** (don't edit shipped ones), the `sample_with_annotation` view
if the UI needs it, and `SampleRow` if the table shows it. For a sortable table column also add a `SampleSort`
case (SQL `key`, `nullable`, `defaultAscending`, `rowsAreInOrder`) and a `SortKey` on `SampleRow`.
