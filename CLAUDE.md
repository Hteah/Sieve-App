# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Sieve is a native SwiftUI macOS app (macOS 26, Swift 6 strict concurrency) that indexes a music producer's
sample folders, shows amplitude-accurate waveforms, lets the user tag/rate/annotate samples, and finds exact
duplicates. Indexing never touches files on disk; the only writes are explicit user actions — Trash/Move in the
Duplicates view and "Convert Sample Rate / Bit Depth" on the list selection (`Audio/AudioConverter`, rewrites in place).

## Build, test, run

The `.xcodeproj` is generated — never edit it by hand; edit `project.yml` and regenerate.

```bash
xcodegen generate                                   # after adding/removing files or changing project.yml
xcodebuild -project Sieve.xcodeproj -scheme Sieve -destination 'platform=macOS' -derivedDataPath build build
xcodebuild -project Sieve.xcodeproj -scheme Sieve -destination 'platform=macOS' -derivedDataPath build test
# single test (swift-testing):
xcodebuild ... test -only-testing:SieveTests/FileOperatorTests/moveInsideRootRepathsAndHandlesCollisions
open build/Build/Products/Debug/Sieve.app
```

Filter xcodebuild output with `grep -E "error:|✘|Test run|BUILD"` — it is very noisy.

Debug builds honour `SIEVE_ADD_ROOT=/path` (see `AppEnvironment.init`) to register a root at launch without the
folder picker. The app is sandboxed, so the path must be sandbox-readable, e.g. inside
`~/Library/Containers/com.arlo.Sieve/Data/Documents/`. Verify UI changes by launching + screenshot; reserve the
test suite for logic changes (indexing, hashing, queries, file ops).

`DEBUG` builds set `eraseDatabaseOnSchemaChange`, so schema edits in `AppDatabase.migrator` wipe the local DB.
Database lives at `~/Library/Containers/com.arlo.Sieve/Data/Library/Application Support/Sieve/library.sqlite`.

## Architecture

**Composition root:** `App/AppEnvironment` (`@MainActor @Observable`) owns `AppDatabase`, `BookmarkStore`,
`ScanCoordinator`, `PreviewPlayer`, `VolumeMonitor`, and is injected via `.environment(env)`. Views get it with
`@Environment(AppEnvironment.self)`. `LibraryViewModel` is created by `ContentView` and drives sidebar + table.

**Persistence (GRDB, only dependency):** schema in `Persistence/AppDatabase.swift` (`migrator`). Key tables:
`root` (security-scoped bookmark per user-added folder), `sample` (one row per file; `status` is
`present | missing | unavailable`; rows are never deleted by scans, only by "Purge Missing"), `sample_fts` (FTS5,
synced by triggers), `tag`, `annotation`, `annotation_tag`, `file_op_log`. The SQL view
`sample_with_annotation` joins samples to annotations and is what the UI reads (`SampleRow`).

**Annotations are keyed by content hash, not path.** `annotation.contentHash` = `sample.audioHash ?? fileHash`,
so ratings/tags/notes survive moves/renames and are shared by all identical copies (`Queries.annotation(db:for:create:)`
is the single lookup/create point). Path-keyed fallback exists only for undecodable files.

**Scan pipeline (`Indexing/ScanCoordinator`, an actor, one Task per root):** resolve bookmark → reachability check
(unreachable ⇒ mark root + samples `unavailable`, never delete) → `FileEnumerator` → `IncrementalScanner.diff`
(pure, tested; 1 s mtime tolerance) → batched writes → enrichment of rows where `indexedAt IS NULL` in a bounded
`TaskGroup`. Progress is published through `progressStream()` (AsyncStream) into `AppEnvironment.scanState`.

**Enrichment is one pass per file** (`Audio/AudioAnalyzer.analyze`): `AVAudioFile` decoded to Float32 →
metadata + SHA-256 over PCM (`audioHash`; container-independent, so WAV/AIFF/extra-chunk copies match) +
`WaveformSummary` (512 buckets × per-channel peak & RMS, stored Float16 in `sample.waveform`) + peak/RMS dBFS
+ clipped-sample count. If AVFoundation can't open the file, only a whole-file `fileHash` is stored.
`WaveformGenerator.summary` re-reads a file at arbitrary resolution for the inspector's zoomed view.

**Sandbox rules:** all file access to a root goes through its bookmark; hold the scope on the *root* URL
(`withSecurityScope` in `BookmarkStore.swift`) — child URLs only inherit while the root's scope is active.
`AppEnvironment.rootURL(for:)` caches resolved root URLs. Two code paths modify files: `FileOperator`
(Duplicates) re-verifies size/mtime against the index before acting, logs to `file_op_log`, and re-paths or
marks `missing` afterwards — its filesystem calls go through the `FileSystemOps` protocol so tests fake the
Trash. `AudioConverter` (batch convert) writes a temp WAV, validates it (rate/channels/length), then replaces
the original in place; a non-WAV source becomes a sibling `.wav` and the original is deleted. The converted
audio gets a new content hash, so `BatchConvertSheet` calls `AnnotationStore.carryOverAnnotation` to copy
rating/tags/notes onto the new hash and then rescans the affected roots.

**Concurrency conventions:** `SWIFT_DEFAULT_ACTOR_ISOLATION` is `nonisolated`. AVFoundation objects
(`AVAudioFile`, `AVAudioPCMBuffer`) never cross isolation boundaries — create and consume them in one actor/task
and emit value types. GRDB records are `Sendable` structs. UI-facing state is `@MainActor @Observable`.

**Adding a column:** update the record struct, the `v1` migration (DEBUG erases on change; add a new migration
for shipped builds), the `sample_with_annotation` view if UI needs it, and `SampleRow` if the table shows it.
