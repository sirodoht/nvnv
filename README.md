# nvnv

nvnv is a native, keyboard-first macOS notes app. A single field searches
existing notes and creates a new note from an unmatched title when Return is
pressed. Note filenames and UTF-8 text contents are authoritative; SQLite is a
disposable search and state cache.

## History and motivation

nvnv is a new implementation of [Notational Velocity](https://notational.net/) in
Swift and Liquid Glass. I've been happy using the [nvALT](https://github.com/ttscoff/nv) fork
for a decade but it has not been updated for the Apple M series architecture and macOS
informed me the app will stop working. This is my replacement.

## How nvnv differs from Notational Velocity and nvALT

nvnv keeps the defining Notational Velocity interaction: one field filters
notes as you type, opens a matching note, or creates a note from a new title.

- It is written in Swift 6 and SwiftUI, with a small AppKit text-editor bridge,
  instead of the original Objective-C and Cocoa implementation. It requires
  macOS 15 or newer.
- A note is always an individual UTF-8 plain-text file. Its filename stem is
  its title, while SQLite is only a rebuildable search and state cache. The
  older apps also support an application-managed database and other file
  formats.
- The selected notes folder is authoritative. nvnv watches for external
  changes, uses atomic writes and crash-recovery journals, presents edit
  conflicts, and prevents two processes from writing to a library at once.
- nvnv focuses on the local plain-text workflow. It does not
  include tags, wiki links, saved searches or bookmarks, encryption, a global
  activation shortcut, external-editor integration, rich-text or HTML
  storage, or Simplenote sync.
- It only has a vertical layout and no rendered markup preview.

## Keyboard shortcuts

- `⌘L` — focus the search/create field.
- Type — filter notes by title and contents.
- `↑` / `↓` — move through results while the search field is focused.
- `⌘J` / `⌘K` — select the next/previous note from anywhere.
- `Return` — open the selected or best title match; if none matches, create a note.
- `Escape` — clear the search or cancel a rename.
- `⌘D` — deselect the note and restore the previous search.
- `⌘R` — rename the selected note. Press `Return` to commit or `Escape` to cancel.
- `⌥⌘←` — return to the previous note/search context.
- `⌘Delete` — move the selected notes to Trash.
- `⇧⌘R` — show the selected note in Finder.
- `⌘[` / `⌘]` — outdent/indent.
- `Tab` / `Shift-Tab` — indent/outdent in the editor when “Tab indents text” is enabled.
- `⌘O` — choose another notes folder.
- Standard macOS editing shortcuts work in the editor: `⌘Z`, `⇧⌘Z`, `⌘F`, `⌘X`, `⌘C`, `⌘V`, and `⌘A`.

## Build and run from source

Requires macOS 15 or newer and Xcode 26 / Swift 6.2 or newer.

```bash
./script/build_and_run.sh
```

The script builds the native Xcode app target, stages `dist/nvnv.app`, stops an
older instance, and opens the new app bundle. It also supports `--verify`,
`--debug` (which uses a debug-symbol build), `--logs`, and `--telemetry`. The
Codex **Run** action is wired to this script.

## Test

```bash
swift test --package-path Packages/NVNVCore
swift run --package-path Packages/NVNVCore nvnv-probes
```

The tests cover query semantics, Unicode matching, deterministic title
selection, filename safety, UTF-8/BOM/CRLF scanning, symlink exclusion,
compare-before-replace conflicts, cache rebuildability, and editor text
transformations. The probe executable verifies FTS5 trigram support, atomic
replacement, directory durability, and the OS-backed library lock.

## Performance

Release-mode engine benchmarks use deterministic notes with 2,048-byte varied
ASCII bodies. Unless noted otherwise, the figures below are medians of seven
runs after one warm-up. They were measured in July 2026 on a 10-core Apple M1
Max MacBook Pro with 64 GB RAM, running macOS 26.5.2.

| Workload | Result |
| --- | ---: |
| Build normalized search documents for 10,000 notes | 345 ms |
| Search 10,000 cached notes, all notes matching | 13 ms |
| Search 10,000 cached notes, no notes matching | 12 ms |
| Selective FTS search across 10,000 notes, one match | 1.8 ms |
| Update one note in SQLite and the FTS index | 12.5 ms |
| Initial filesystem scan of 10,000 notes | 2.23 s |
| Warm metadata scan of 10,000 unchanged notes | 438 ms |
| Scan one externally changed file in a 10,000-note library | 16 ms |
| Search 50,000 cached notes, no notes matching | 63 ms |

The initial scan is a single-run setup measurement; steady-state rows use the
seven-sample method above.

These are core search, indexing, and filesystem measurements; they do not
include SwiftUI list rendering or complete application-launch latency. The load
test also identifies a current bottleneck: constructing the complete SQLite
trigram index for 10,000 × 2 KB notes takes about 27 seconds. Cache construction
is therefore not represented by the steady-state search figures above.

Run the same benchmark locally with:

```bash
swift run -c release --package-path Packages/NVNVCore nvnv-probes --benchmark
```

## Documentation

The full product behavior is defined in the [nvnv SPEC](spec/SPEC.md).
Architecture decisions are recorded in [`docs/architecture`](docs/architecture).
Release history is recorded in the [changelog](CHANGELOG.md).

## License

nvnv is available under the [MIT License](LICENSE).
