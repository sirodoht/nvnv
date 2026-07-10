# nvnv

nvnv is a native, keyboard-first macOS notes app. A single field searches
existing notes and creates a new note from an unmatched title when Return is
pressed. Note filenames and UTF-8 text contents are authoritative; SQLite is a
disposable search and state cache.

## Run

Requires macOS 15 or newer and Xcode 26 / Swift 6.2 or newer.

```bash
./script/build_and_run.sh
```

The script builds an optimized release product, stages `dist/nvnv.app`, stops
an older instance, and opens the new app bundle. It also supports `--verify`,
`--debug` (which uses a debug-symbol build), `--logs`, and `--telemetry`. The
Codex **Run** action is wired to this script.

## Test

```bash
swift test
.build/debug/nvnv-probes
```

The tests cover query semantics, Unicode matching, deterministic title
selection, filename safety, UTF-8/BOM/CRLF scanning, symlink exclusion,
compare-before-replace conflicts, cache rebuildability, and editor text
transformations. The probe executable verifies FTS5 trigram support, atomic
replacement, directory durability, and the OS-backed library lock.

Architecture decisions are recorded in [`docs/architecture`](docs/architecture).
