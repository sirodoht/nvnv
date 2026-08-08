# Changelog

All notable changes to nvnv are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.4.0] - 2026-08-08

### Added

- Added in-place note renaming with Return to commit and Escape to cancel.
- Pressing Return in the note list now focuses the selected note in the editor.

### Changed

- Made explicit note selection show the selected title without replacing the
  active search query.
- Made Command-D fully return to search by restoring focus and the prior query,
  clearing note selection, and scrolling results to the top.
- Improved warm startup by reconciling only changed cache records and avoiding
  database writes when the notes library is unchanged.
- Refined the read-only library notice and the final note-row separator.

### Fixed

- Routed editor undo and redo commands through the active editing session.
- Refreshed detected links after paste, edits, indentation, undo, and redo.
- Corrected Tab, Shift-Tab, indent, and outdent behavior for carets and
  selections.
- Revealed the remembered cursor position when focusing a long note.
- Preserved native macOS elastic scrolling while keeping the first note below
  the table header at launch and after returning to the top.

## [1.3.0] - 2026-08-07

### Added

- Added find shortcuts to the note editor.

### Changed

- Removed the delete-note shortcut from the note editor to prevent accidental
  deletion while editing.

### Fixed

- Fixed note-list search and display regressions.
- Persisted resized note-list column widths across launches.

## [1.2.0] - 2026-07-16

### Added

- Added inline title completion while searching.
- Added automatic link detection for URLs and email addresses in existing notes.
- Added configurable note-list columns that can be shown, hidden, reordered,
  and resized.

### Changed

- Improved note-list column behavior and persistence.
- Simplified the available editor font settings.

### Fixed

- Strengthened autosaving and conflict handling during simultaneous local and
  external changes.
- Preserved unsaved edits across external renames and before destructive
  operations.
- Handled simultaneous conflicts without blocking unrelated notes.
- Preserved file metadata during atomic saves.
- Cleared stale undo history after an external replacement.

## [1.1.0] - 2026-07-12

### Added

- Added reproducible benchmarks for search, indexing, filesystem scanning, and
  external-change handling, together with published performance results.

### Changed

- Made external note updates incremental so changing one file no longer rebuilds
  the entire in-memory search state and SQLite cache.
- Improved responsiveness while refining searches with large result sets.
- Start each launch with an empty search and no selected note instead of restoring
  the previous session's query and selection.
- Pressing Command-L now selects all text when the search field already has focus.

### Fixed

- Rescan the library when an external rename cannot be represented reliably by a
  single filesystem event.
- Made reconciliation of externally deleted notes scale linearly with library
  size.

## [1.0.0] - 2026-07-11

### Added

- Initial public release of nvnv.
- Unified note search and creation with keyboard-first navigation.
- Notes stored as individual UTF-8 plain-text files.
- Automatic saving, crash recovery, external-change detection, and edit-conflict
  handling.
- Native support for Apple silicon and Intel Macs running macOS 15 or newer.

[1.4.0]: https://github.com/sirodoht/nvnv/compare/v1.3.0...v1.4.0
[1.3.0]: https://github.com/sirodoht/nvnv/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/sirodoht/nvnv/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/sirodoht/nvnv/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/sirodoht/nvnv/releases/tag/v1.0.0
