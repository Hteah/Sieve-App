# Sieve

A lightweight native macOS app for organizing music-production sample collections.

- **Index** one or more folders (local, external drive, NAS). Files are never moved or modified by indexing;
  rescans are incremental and an unplugged drive just shows as *unavailable* — nothing is forgotten.
- **See amplitude**: every row shows a stereo-lane waveform with peak outline and RMS body; the inspector has a
  zoomable full-resolution waveform plus peak dBFS, RMS dBFS and a clipping counter.
- **Preview** with Space or double-click; click the waveform to seek.
- **Edit** in the inspector's Edit tab (or a pop-out window): drag-select a region, then trim, delete,
  normalize, amplify, reverse, fade, silence, cut/copy/paste, with undo/redo and looped selection playback.
  Save to a new WAV or replace the original in place.
- **Record** from the audio input straight to a 24-bit WAV in a folder you pick once (Record button in the
  editor, with a live input meter). Auto-named per take; shows up in the library if the folder is indexed.
- **Tag, rate, favorite, annotate.** Metadata is keyed by the audio content hash, so it follows files that are
  renamed or moved, and identical copies share it.
- **Find exact duplicates** across packs (WAV vs AIFF vs re-tagged copies of the same audio all match). Choose
  which copy to keep, then trash or move the rest — with a confirmation sheet and an operations log.
- **Batch convert** the selected rows' sample rate and bit depth (right-click → *Convert Sample Rate / Bit
  Depth*). Rewrites the originals in place as WAV using a mastering-grade resampler; ratings/tags/notes are
  carried across to the converted audio.
- BPM/key are parsed from filenames (`_128bpm`, `Cmin`, `F#m`); audio-based detection is a later phase.

## Requirements

- macOS 26, Xcode 26.6+
- [xcodegen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`

## Build & run

```bash
xcodegen generate                                        # creates Sieve.xcodeproj (git-ignored)
open Sieve.xcodeproj                                     # run from Xcode, or:
xcodebuild -project Sieve.xcodeproj -scheme Sieve -destination 'platform=macOS' -derivedDataPath build build
open build/Build/Products/Debug/Sieve.app
```

Then **File → Add Folder…** (⌘O) and pick a sample folder. **⌘R** rescans everything.

## Tests

```bash
xcodebuild -project Sieve.xcodeproj -scheme Sieve -destination 'platform=macOS' -derivedDataPath build test \
  2>&1 | grep -E "error:|✘|Test run"
```

Tests use swift-testing with an in-memory database and generate their own WAV/AIFF fixtures; nothing outside a
temp directory is touched.

## Layout

```
project.yml          xcodegen spec: targets, entitlements, GRDB package
Sieve/
  App/               entry point, AppEnvironment (composition root), menu commands, ContentView
  Persistence/       GRDB schema + records, queries/filters, annotation writes
  Indexing/          bookmarks, volume monitor, file enumeration, incremental diff, ScanCoordinator
  Audio/             AudioAnalyzer (metadata+hash+waveform+levels), WaveformSummary, PreviewPlayer
  Duplicates/        DuplicateFinder, FileOperator (trash/move behind a FileSystemOps protocol)
  Features/          SwiftUI: Sidebar, Library (table + filter bar), Inspector, Duplicates, Scanning
  Shared/            WaveformView, StarRatingView, FilenameHints, formatters
SieveTests/          unit tests + fixture generator
```

Dependencies: [GRDB.swift](https://github.com/groue/GRDB.swift) only. Everything else is Apple frameworks.

## Notes

- The app is sandboxed; folder access is persisted with security-scoped bookmarks. Trash may fail on some
  external volumes without a `.Trashes` folder — the results sheet offers permanent deletion in that case.
- Debug builds accept `SIEVE_ADD_ROOT=/path` to add a root at launch (path must be sandbox-readable).
