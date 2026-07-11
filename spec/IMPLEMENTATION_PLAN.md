# nvnv Implementation Plan

Status: Draft 1  
Product contract: `SPEC.md`  
Scope checklist: `NVNV_FEATURES.md`  
Historical reference only: `NVALT_SPEC.md`

## 1. Objective

Build nvnv as a local, keyboard-first notes application whose user-visible notes are authoritative UTF-8 text files.

The primary workflow is:

1. Focus the search field.
2. Type to filter notes by title and body.
3. Select and edit an existing result, or press Return on an unmatched non-empty title to create a note.
4. Rely on automatic, atomic persistence with no Save command.

The implementation is complete only when deleting or rebuilding SQLite cannot lose or change a note.

## 2. Non-negotiable architecture rules

These rules apply from the first implementation milestone:

- Filename stem is authoritative for note title.
- Text-file contents are authoritative for note body.
- SQLite is a disposable search index and application-state cache.
- A successful file operation is never rolled back merely because SQLite failed.
- Search semantics are defined by nvnv, not by SQLite FTS syntax or ranking.
- Raw search-field input is never passed directly to FTS.
- Every file replacement compares against the last observed file before overwriting.
- A two-sided change always preserves both versions and enters conflict resolution.
- At most one process may write a library.
- The only normal in-app creation path is a non-empty unmatched title in the search field followed by Return.
- No tags, untitled notes, rich text, preview, synchronization, encryption, import/export, horizontal layout, or collapsed-list mode are introduced.

## 3. Application stack and remaining technical decisions

### 3.1 Chosen stack

- Target: native macOS desktop application.
- Language: Swift.
- Primary UI framework: SwiftUI.
- Visual design: the current system Liquid Glass design language, adopted primarily through standard SwiftUI controls, bars, sheets, menus, and materials.
- Platform bridges: AppKit through narrow adapters or `NSViewRepresentable` only where required for mature text editing, per-note undo, window/focus behavior, file coordination, workspace integration, or another capability SwiftUI cannot satisfy reliably.
- Unit and direct integration tests: Swift Testing.
- UI automation and performance tests: XCTest with XCUIAutomation.
- Persistence tests: real temporary directories and SQLite databases, not mocks alone.
- Crash tests: subprocess-based failpoint runner that terminates the implementation at named durability boundaries.

Liquid Glass is a functional control/navigation layer, not a decorative coating over note content. The note list and editor must remain calm, legible content surfaces. Prefer automatic system adoption; use custom `glassEffect` only when a standard component cannot express an important control. Test increased contrast, reduced transparency, reduced motion, active/inactive windows, light appearance, and dark appearance.

### 3.2 Decisions to record in Milestone 0

Milestone 0 must record these remaining choices as short architecture decision records:

1. Minimum macOS version and Xcode/Swift toolchain version.
2. Xcode project structure and which domain components are separate Swift packages or framework targets.
3. Text-editor implementation and how per-note undo histories will be isolated.
4. SQLite distribution/wrapper strategy and confirmation that FTS5 trigram support is available in the deployed runtime.
5. Filesystem watcher and file-coordination APIs.
6. Exclusive library-lock implementation and cross-process focus/activation mechanism.
7. Trash and Show in Finder adapters.
8. Logging, diagnostics, and redaction policy.

Do not begin UI feature work until SQLite, filesystem watching, atomic replacement, and process locking have small executable probes on the supported macOS versions.

## 4. Proposed component boundaries

| Component | Responsibility | Must not own |
|---|---|---|
| Domain | Note snapshots, queries, commands, conflicts, navigation state | Filesystem or UI APIs |
| Library scanner | Enumerate and decode authoritative note files | Search semantics |
| File repository | Create, compare, replace, rename, trash, and reveal files | SQLite authority |
| Recovery journal | Persist pending mutations, write intents, and recovery state | Canonical saved notes |
| Cache repository | SQLite schema, derived rows, hashes, cursor state, settings cache | Final title/body authority |
| Search service | Parse, generate candidates, overlay dirty notes, verify, sort | File mutations |
| Watcher/reconciler | Convert filesystem events into self-write acknowledgements or external changes | UI-specific conflict presentation |
| Command service | Execute create, edit, rename, delete, undo, and redo transitions | Direct widget manipulation |
| Conflict service | Preserve versions and execute chosen resolution | Silent last-write-wins behavior |
| UI state | Focus, selection, columns, divider, history, and read-only state | Direct durable writes |
| Platform adapters | Locks, trash, file reveal, URL opening, full screen, file coordination | Product rules |

Dependency direction should flow toward the domain. Platform and UI implementations depend on domain interfaces, not the reverse.

## 5. Core data flows

### 5.1 Library open

```text
Acquire writer lock or choose read-only
  → scan recognized regular UTF-8 files
  → compare file identity/hash with SQLite cache
  → rebuild or update derived rows
  → recover journal entries if writable
  → expose immutable note snapshots to UI
```

### 5.2 Search

```text
Search-field generation
  → nvnv query parser
  → SQLite trigram candidates or fallback scan
  → dirty in-memory overlay
  → exact normalized substring/phrase verification
  → configured list sort
  → automatic title selection
  → publish only if generation is still current
```

### 5.3 Save

```text
Editor command
  → in-memory note mutation
  → durable journal entry
  → temporary UTF-8 file
  → compare current destination identity/hash with base
  → coordinated atomic replace
  → verify resulting file and directory durability
  → mark journal operation applied
  → update SQLite cache/index
```

### 5.4 External change

```text
Filesystem event
  → debounce and inspect actual file state
  → match against journaled nvnv write intent
  → acknowledge self-write OR classify external change
  → one-sided refresh OR durable conflict state
  → clear affected editor undo history and notify when body changed externally
```

## 6. Delivery milestones

Each milestone ends with a demonstrable vertical slice and a required test gate. Later milestones must not compensate for an unmet earlier gate.

### Milestone 0 — Repository and platform foundation

Goal: establish a buildable, testable application skeleton and retire platform feasibility risks.

Deliverables:

- Architecture decision records for every choice in section 3.
- Application and test targets with formatting, linting, and static analysis.
- Continuous integration for every supported macOS/toolchain configuration.
- Structured error and diagnostic types with note-body redaction.
- Temporary-library test fixture.
- Deterministic clock, UUID, and filesystem abstractions for tests.
- Failpoint mechanism capable of terminating a subprocess at named persistence boundaries.
- Executable probes for:
  - SQLite FTS5 trigram queries
  - Atomic replacement and directory durability
  - Case-only rename
  - File watching during atomic replacement
  - OS-backed exclusive library lock
  - Move to trash and reveal in file manager

Exit gate:

- A clean checkout builds and runs tests in CI.
- Every probe succeeds or has an approved fallback documented before product code depends on it.
- Test code can create, mutate, and destroy an isolated library without touching user data.

### Milestone 1 — File-authoritative library core

Goal: open a folder and derive a trustworthy note collection without requiring UI or a pre-existing cache.

Deliverables:

- Library path validation.
- `.nvnv` auxiliary-directory management.
- Recognized/default extension configuration, initially `.txt`.
- Root-level, non-recursive file scanner.
- UTF-8 and BOM decoding with invalid-file reporting.
- Regular-file enforcement; ignore symlinks, aliases, and special files.
- Duplicate hard-link detection.
- Note snapshot model derived from filename and file contents.
- Best-effort filesystem timestamps.
- Safe filename construction and collision suffixing.
- SQLite cache schema and migrations.
- Full cache rebuild from note files.
- Incremental cache refresh using path, file identity, timestamps, and hash.
- Single-writer lock and read-only library session.

Tests:

- Empty library, large library, mixed extensions, invalid UTF-8, BOM, CRLF, and Unicode filenames.
- Hidden files, subdirectories, symlinks, hard links, and special files.
- Case-sensitive and case-insensitive filesystems where CI permits.
- Delete, corrupt, and replace `index.sqlite3`; reopening yields the same titles and bodies.
- Two processes cannot both obtain write access.
- Writer crash releases the OS lock without manual cleanup.

Exit gate:

- A headless integration test opens a library and emits the expected immutable note snapshots.
- Rebuilding SQLite changes no note file bytes, names, or timestamps.
- A read-only second process can scan and inspect library data without writing shared state.

### Milestone 2 — Exact incremental search

Goal: implement nvnv search semantics independently of the UI framework.

Deliverables:

- Query parser for whitespace-separated AND terms and quoted phrases.
- Literal handling of colons, punctuation, `AND`, `OR`, and `NOT`.
- Unicode normalization and case-folding service.
- Normalized shadow title/body fields for candidate generation.
- FTS5 trigram candidate index.
- Fallback scanning for one- and two-character terms.
- Exact application-level substring and phrase verifier.
- Dirty-note overlay interface.
- Configured title/date sorting after verification; never rank ordering.
- Exact and shortest-prefix automatic title selection.
- Monotonic search generations with cancellation/late-result rejection.
- Match ranges suitable for editor highlighting.
- Deterministic 10,000-note performance fixture.

Tests:

- Every query example and edge case in `SPEC.md` section 6.
- Terms split across title and body.
- Mid-word substrings, short terms, punctuation, quotes, and malformed quotes.
- Unicode normalization pairs and case-folding edge cases.
- Dirty overlay adds, replaces, and removes cached results correctly.
- Deliberately delayed older queries never replace newer results.
- Missing, corrupt, stale, or rebuilding index returns complete results through fallback.
- Fuzz tests never turn user input into FTS syntax errors or operators.

Exit gate:

- Search-result update p95 is at most 150 ms for the reference library on baseline hardware.
- Exact-verifier tests prove candidate generation has no false negatives.
- Deleting SQLite before a query changes performance temporarily but not results.

### Milestone 3 — Read-only application shell

Goal: deliver the complete browsing and navigation experience before enabling mutation.

Deliverables:

- One vertical window containing search field, note list, and editor.
- Resizable and persisted note-list/editor divider.
- Search-field focus and incremental result updates.
- Result selection by pointer, Up/Down, and Primary-J/Primary-K.
- Read-only note body display.
- Empty and multiple-selection states.
- Title, Date Modified, and Date Created columns.
- Column visibility, order, width, and sorting.
- Optional two-line body excerpts.
- Duplicate-stem filename/extension disambiguation.
- Word-count display.
- Search highlighting.
- Full-screen behavior.
- Per-note cursor/selection restoration in memory.
- Back/snapback navigation state.
- Clear persistent read-only-library indication.

Tests:

- Keyboard-only navigation from search to list to editor and back.
- Sorting and filtering preserve valid selection.
- Duplicate stems remain visually distinguishable.
- Divider, columns, and per-note cursor metadata persist after relaunch; query,
  selection, and list offset reset to the fresh launch state.
- Late search results do not disturb current focus or selection.

Exit gate:

- A user can open an existing folder, search, navigate, read, and reveal every valid note without mutation.
- The read-only UI attempts no shared file, journal, or SQLite writes.

### Milestone 4 — Commands, editing, and autosave

Goal: complete the primary create/edit/rename/delete loop with file-first durability.

Deliverables:

- Domain command model for create, body edit, rename, delete, undo, and redo.
- Creation only through Return on a non-empty unmatched search-field title.
- No New Note command or untitled/provisional state.
- Plain-text editor with one session undo history per note.
- Dirty-note search overlay.
- Autosave debounce of 750 ms and hard deadline of 10 seconds.
- Versioned recovery-journal format with integrity checking.
- Journaled write-intent ledger.
- Compare-before-replace file writer.
- Coordinated atomic replacement with previous-byte preservation until verification.
- Cache/index update only after authoritative file success.
- Explicit Rename mode in the search field.
- Case-only rename through a safe temporary path.
- Delete to trash and grouped multi-note deletion.
- Application undo/redo for create, rename, and deletion.
- Show in File Manager.
- Mandatory flush on quit, suspension, library switch, and directory change.
- Startup journal replay and recovery-conflict creation.

Tests:

- Complete search → create → edit → autosave → restart flow.
- Return opens an explicit/automatic match and creates only when neither exists.
- Empty search and Primary-N cannot create a note.
- File bytes update before SQLite and remain correct if SQLite fails.
- Continuous typing is saved within 10 seconds.
- Independent note undo histories survive note switching during the session.
- Rename, case-only rename, delete, and grouped undo are recoverable.
- Disk-full and permission errors preserve the prior complete file.

Exit gate:

- A keyboard-only user can create, edit, rename, delete, undo, and reveal notes.
- No successful user workflow depends on SQLite as the sole copy of title or body.
- Kill tests at journal and file-write boundaries yield old, new, or explicit-conflict states only.

### Milestone 5 — Filesystem watching and conflict resolution

Goal: make simultaneous use with external editors safe and understandable.

Deliverables:

- Root watcher with debounce, overflow detection, and full-rescan fallback.
- Matching by file identity, path, hash, and timestamps.
- Recognition of nvnv's own create/replace/rename/delete events using write intents.
- Content-identical external rewrite handling.
- External create, modify, rename, and delete reconciliation.
- Undo-history clearing and brief notification after external body change.
- Durable conflict state containing base, app, and every observed file version.
- Read-only conflicted-note state.
- Conflict resolver with:
  - Keep App
  - Use File
  - Keep Both
  - Merge
  - Open File Externally
- Recheck before Keep App or Merge commits.
- Conflict persistence across restart.

Tests:

- nvnv's own atomic save produces no duplicate or false conflict.
- External edit before save enters conflict rather than being overwritten.
- External edit during replacement preserves both versions.
- External file changes again while resolver is open.
- Each resolution choice produces the specified file and cache state.
- External rename during in-app rename.
- External delete with and without pending local changes.
- Watcher overflow and event reordering converge after rescan.
- Cloud-folder-style create/rename/delete event bursts converge without loss.

Exit gate:

- Two editors can intentionally race on one note without silent data loss.
- Every conflict can be dismissed, survived across restart, and resolved later.
- All self-write and external-write tests converge to filesystem truth.

### Milestone 6 — Editor and productivity behavior

Goal: complete retained editing, navigation, and preference behavior.

Deliverables:

- Cut, copy, plain-text paste, clear, select all, undo, and redo.
- Find, Find Next, and Find Previous in the current note.
- Indent and outdent across selected lines.
- Hard tabs and configurable soft tabs/tab width.
- Tab-to-indent preference and focus-navigation fallback.
- New-line indentation inheritance.
- Bullet and numbered-list continuation and termination.
- URL recognition and explicit opening.
- Editor font family/size preference.
- Note-list font-size preference.
- Body-excerpt and word-count preferences.
- Delete-confirmation and search-highlighting preferences.
- Complete keyboard command table and menu exposure.
- Session back/snapback behavior.
- Session-only query, selection, list offset, and back/snapback state.
- Persisted per-note cursor metadata, columns, divider, and window state.

Tests:

- Deterministic text-transformation unit tests using cursor/selection fixtures.
- Per-note undo does not cross note boundaries.
- External body refresh clears undo/redo and displays the notification once.
- URL activation requires an explicit action.
- Every retained pointer action has a keyboard path.
- Preferences apply immediately and survive restart at their documented scope.

Exit gate:

- Every retained editor and keyboard acceptance criterion passes.
- The full normal workflow is comfortable without a pointer.

### Milestone 7 — Reliability, performance, and release hardening

Goal: prove the complete system under failure, scale, and unusual filesystem conditions.

Deliverables:

- Complete automated crash matrix from `SPEC.md` section 16.
- Long-running watcher/reconciliation stress tests.
- Fuzzing for query parsing, filename construction, journal decoding, and conflict transitions.
- Large-note and 10,000-note profiling.
- Startup index validation and background rebuild progress.
- Bounded-memory loading and rendering strategy.
- Actionable error UI for every error class in `SPEC.md` section 17.
- Diagnostics export that excludes note bodies.
- macOS packaging, signing, notarization, and release process.
- User documentation for:
  - Search/create interaction
  - File-authoritative storage
  - Read-only library state
  - External conflicts
  - Recovery after a failed save

Required crash failpoints:

- Before and after journal durability.
- During temporary-file writing.
- After temporary-file flush and before destination comparison.
- After comparison and before replacement.
- After replacement and before directory metadata durability.
- After file success and before SQLite update.
- Every stage of case-only rename.
- During move to trash.

Exit gate:

- Warm launch, search, note-switch, and typing latency meet the specification.
- No crash test produces a truncated note or loses both sides of a conflict.
- Rebuilding all auxiliary data from files succeeds repeatedly.
- Every MUST in `SPEC.md` has an automated test or documented manual verification.

## 7. Test strategy

### 7.1 Unit tests

Keep these deterministic and free of real UI/filesystem dependencies where possible:

- Query parsing and exact verification
- Unicode normalization and title comparison
- Automatic title selection
- Filename sanitization and collision handling
- Sorting and selection rules
- Editor indentation and list continuation
- Word counting
- Command/undo state transitions
- Conflict state machine
- Journal encoding, integrity, and replay decisions

### 7.2 Filesystem integration tests

Run against isolated real directories:

- Atomic create/replace/rename/delete
- Compare-before-replace races
- Watcher self-events and external events
- Lock acquisition across subprocesses
- Trash and reveal adapters
- Case-only rename
- Symlink, hard-link, Unicode, long-name, and permission behavior
- SQLite deletion/corruption and rebuild

### 7.3 Crash tests

Run a child application or repository process with named failpoints. The parent kills it, reopens the library, and verifies:

- Authoritative file bytes
- Journal contents
- Recovery result
- Conflict preservation
- Cache rebuildability
- Lock release

### 7.4 UI automation

Cover complete keyboard workflows:

- Focus search
- Search and select
- Open or create with Return
- Edit and switch notes
- Rename
- Multi-select and delete
- Undo/redo
- Find and indentation
- Back/snapback
- Conflict resolution
- Read-only second process

### 7.5 Performance tests

Use a committed deterministic generator, not user notes. Record hardware and build configuration with results.

- 10,000-note launch and index validation
- Full index rebuild
- One-, two-, and long-character searches
- Rapid query cancellation/generation churn
- Large-note editor switch and highlighting
- Watcher burst and full rescan
- Memory high-water marks

## 8. CI and quality gates

Every pull request should run:

- Formatting and linting
- Static analysis/type checks
- Unit tests
- SQLite/search integration tests
- Filesystem tests supported by the runner
- A focused crash-test subset

Main-branch or nightly CI should additionally run:

- Complete crash matrix
- Multi-process lock tests
- Watcher stress tests
- Query/parser fuzzing
- 10,000-note performance suite
- Cache rebuild and corruption suite

A release candidate cannot proceed with a known data-loss, silent-overwrite, cache-authority, or dual-writer defect.

## 9. Suggested initial issue sequence

Create small, independently reviewable issues in this order:

1. Select stack and write architecture decisions.
2. Scaffold application, tests, CI, and failpoint runner.
3. Implement library lock probe and production adapter.
4. Implement note-file scanner and UTF-8 decoder.
5. Implement filename/title rules and filesystem edge cases.
6. Implement SQLite cache schema and full rebuild.
7. Implement query parser and exact verifier.
8. Implement FTS5 trigram candidate index and short-query fallback.
9. Implement search generations, sorting, and title auto-selection.
10. Build the read-only vertical UI shell.
11. Implement recovery journal and write-intent format.
12. Implement compare-before-replace atomic writer.
13. Implement search-field creation and body autosave.
14. Implement rename, delete, and command undo.
15. Implement watcher and self-write reconciliation.
16. Implement external-change and conflict state machines.
17. Build conflict-resolution UI.
18. Complete editor productivity behavior.
19. Run reliability/performance hardening and release gates.

## 10. Traceability

| Specification area | Primary milestone |
|---|---:|
| Product principles and non-goals | 0 |
| Note model and timestamps | 1 |
| Main window and focus | 3 |
| Search/create state machine | 2, 4 |
| Note lifecycle and undo | 4 |
| Note list | 3, 6 |
| Editor behavior | 4, 6 |
| Keyboard commands | 3, 4, 6 |
| File-authoritative library | 1 |
| Single-writer lock | 1 |
| Autosave and recovery | 4, 7 |
| External files and conflicts | 5 |
| Back/snapback | 3, 6 |
| Preferences | 6 |
| Performance, reliability, and errors | 7 |
| Acceptance criteria | All milestones |

## 11. Implementation definition of done

Implementation is complete when:

- All milestone exit gates pass.
- The product can be used end-to-end with only the keyboard.
- Files remain the sole authority for titles and bodies.
- SQLite can be deleted and rebuilt without changing notes.
- Concurrent external edits never cause silent loss.
- A second process never gains simultaneous write access.
- Every crash boundary yields an old version, new version, or explicit conflict containing both.
- Search behavior is exact for substrings, phrases, short terms, Unicode, and dirty edits.
- Performance targets pass on documented baseline hardware.
- Every MUST in `SPEC.md` has traceable automated or manual verification.
- No pruned feature has been reintroduced accidentally.
