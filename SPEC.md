# nvnv Product and Behavior Specification

Status: Draft 1  
Scope source: `NVNV_FEATURES.md`  
Historical reference: `NVALT_SPEC.md`

## 1. Purpose

nvnv is a local, keyboard-first notes application. Its defining interaction is a single **search field** used both to search existing notes and to name new ones.

This document defines the behavior to implement. It intentionally contains only the features retained in `NVNV_FEATURES.md`.

The words **MUST**, **MUST NOT**, **SHOULD**, **SHOULD NOT**, and **MAY** describe requirement strength:

- **MUST** and **MUST NOT** define required behavior.
- **SHOULD** and **SHOULD NOT** define the expected behavior unless a documented platform constraint prevents it.
- **MAY** defines permitted but optional behavior.

## 2. Product principles

### 2.1 Keyboard first

Every routine action MUST be possible without a pointer. This includes searching, creating, selecting, editing, renaming, deleting, navigating, finding text, and revealing a note file.

### 2.2 Search and creation are one flow

The only in-application way to create a note is through the search field. The user types a title, the note list filters immediately, and pressing Return opens a selected match or creates an empty-body note whose title is the entered text. There is no separate New Note command and no untitled-note state.

### 2.3 Plain text

A note body is Unicode plain text. nvnv does not store or edit rich-text attributes. Text that resembles Markdown remains ordinary note text; this specification does not define Markdown rendering or Markdown-specific editing.

### 2.4 Automatic persistence

There is no normal Save command. User changes are saved automatically, written atomically, and recoverable after a crash within the bounds defined in this specification.

### 2.5 Local ownership

nvnv MUST work entirely from a folder of user-visible plain-text files. Those files are the sole authority for note titles and bodies. SQLite MAY index and cache them, but deleting or rebuilding SQLite MUST NOT lose or change a note.

## 3. Explicit non-goals

The following are outside the scope of this specification:

- Tags or tag metadata of any kind
- Wiki links or note-title completion
- Bookmarks and saved searches
- Rich-text formatting
- Markdown, Textile, or HTML preview
- General-purpose file, clipboard, web, or legacy-database import
- General-purpose export or printing
- Synchronization and online accounts
- Encryption or application locking
- Sharing, publishing, deep links, or scripting APIs
- Global activation shortcuts, menu-bar operation, or system search indexing
- Attachments
- Database-authoritative note storage or storage-mode switching
- Untitled/provisional notes or a separate New Note command

Recognized URLs are clickable text only. They do not become a separate link data type.

## 4. Note model

Every note MUST contain these logical fields:

| Field | Type | Meaning |
|---|---|---|
| `id` | UUID | Auxiliary identity that remains stable during normal operation and may be regenerated if metadata is rebuilt |
| `title` | String | User-visible note title |
| `body` | String | Unicode plain text |
| `created_at` | Timestamp | Time the note was created or first discovered |
| `modified_at` | Timestamp | Time of the last title or body change |
| `cursor_start` | Integer | Last caret or selection start in the body |
| `cursor_length` | Integer | Last selection length in the body |
| `revision` | Integer | Monotonically increasing local content revision |
| `filename` | String | Authoritative filename from which the title is derived |
| `last_saved_hash` | String | Cached hash of the last observed authoritative file state |
| `deleted_at` | Timestamp or null | Auxiliary deletion marker used for undo and recovery |

### 4.1 Title rules

- The title MUST equal the note filename without its recognized extension.
- A title entered inside nvnv MUST contain at least one non-whitespace character after trimming.
- nvnv-created titles MUST NOT contain control characters or line breaks.
- Title search and comparison MUST use Unicode normalization and case-insensitive matching without changing the stored filename.
- An externally created filename stem is preserved exactly. Control characters or unusual whitespace MUST be escaped safely for display rather than silently renaming the file.
- An in-application create or rename that would collide with an existing path MUST use or propose a numeric suffix such as `Meeting 2`.
- Externally created files with the same title stem but different recognized extensions MAY coexist. Search and selection MUST resolve them deterministically using list order and then filename.
- A note's auxiliary ID MUST remain unchanged when its file is renamed during normal operation.

### 4.2 Body rules

- A body MAY be empty.
- The application MUST preserve valid Unicode text.
- Internally, text MUST use `\n` line endings.
- Note files MAY be read with `\n` or `\r\n`; a file's existing line-ending style SHOULD be preserved when it is rewritten.
- NUL characters MUST be rejected or replaced with a visible Unicode replacement character after warning.

### 4.3 Timestamp rules

- `created_at` comes from filesystem birth time when available. Otherwise it is the first discovery time stored in the auxiliary cache and may be regenerated if that cache is lost.
- Creation time is best-effort metadata. Copying, restoring, or moving a file across filesystems MAY change it; nvnv MUST NOT present it as permanently embedded note data.
- `modified_at` comes from the authoritative file's modification time.
- Creating or editing a note updates the file modification time normally.
- An in-application rename MUST update the file modification time because it is a user-visible title change. An external rename MAY retain the filesystem-provided modification time.
- Moving the cursor, changing the selection, searching, sorting, or resizing the window MUST NOT update `modified_at`.
- Undoing or redoing a title or body change is itself a new user-visible change and updates `modified_at`.
- Timestamps MUST be interpreted as absolute instants and displayed in the user's local timezone.

## 5. Main window

The normal application window MUST present these three areas at the same time:

1. Search field
2. Note list
3. Note editor

Secondary status text MAY show a word count, selection count, save state, or recovery error without replacing those areas.

### 5.1 Vertical layout

In vertical layout:

- The search field appears above the note list.
- The note list appears above the editor.
- A resizable divider separates the list and editor.

### 5.2 Layout persistence

nvnv MUST remember, per library:

- Divider position
- Window size and position where the platform permits it
- Full-screen state where restoring it follows platform conventions

### 5.3 Focus order

The default keyboard focus order is search, note list, editor, then back to search.

- Focusing search MUST select its current contents when focus arrived through the Focus Search command.
- Focusing the editor MUST restore the current note's last valid selection.
- If the saved selection is beyond the end of the body, it MUST be clamped to the body length.
- When Tab is configured to indent, Tab in the editor is consumed by the editor; another platform-appropriate focus-navigation key MUST remain available.

### 5.4 Empty and multiple-selection states

- With no selected note, the editor is read-only and shows `No Note Selected`.
- With several selected notes, the editor is read-only and shows the number selected.
- Delete operates on every selected note.
- Commands that require exactly one note, such as Rename or Show in File Manager, MUST be disabled for a multiple selection.
- Moving from multiple selection to one note restores that note's editor and cursor state.

### 5.5 Full screen

nvnv MUST use the platform's standard full-screen behavior where available. Entering or leaving full screen MUST preserve the current query, note selection, cursor, and divider position.

## 6. Search and creation

The search field contains a query during normal use. It becomes a title editor only during an explicit Rename operation.

Typing in the field MUST NOT rename the current note.

### 6.1 Search scope

Search covers only:

- Note title
- Note body

There are no hidden metadata fields or tags in the search index.

### 6.2 Query syntax

- Search is case-insensitive and Unicode-aware.
- Unquoted text is split on Unicode whitespace.
- Every unquoted token MUST match; tokens use AND semantics.
- A token matches when it is a substring of either the title or body.
- Text enclosed in straight double quotes is one phrase and also uses substring matching.
- Quoted phrases and unquoted tokens may be combined; every term MUST match.
- A backslash MAY escape a quote or backslash inside a quoted phrase.
- An unmatched opening quote treats the remaining text as an ordinary phrase while the user is still typing.
- A colon is an ordinary query character; it does not introduce a field operator or split a token.
- Words such as `AND`, `OR`, and `NOT` are ordinary search terms. The search field does not expose SQLite FTS query syntax.
- An empty or whitespace-only query shows all notes.

Examples:

| Query | Match rule |
|---|---|
| `project` | `project` occurs in title or body |
| `project alpha` | Both `project` and `alpha` occur, possibly in different fields |
| `"project alpha"` | The exact phrase occurs in title or body |
| `project "alpha release"` | Both the token and phrase occur |

### 6.3 Incremental results

- Results MUST update as the user types without requiring Return.
- The list MUST retain the configured sort order; relevance does not replace that order.
- Search work MUST NOT block editor typing.
- The implementation MAY debounce indexing work, but visible search results SHOULD update within 50 ms for ordinary libraries and MUST meet the performance targets in section 16.

### 6.4 Search highlighting

- Every visible match in the editor SHOULD be highlighted while a non-empty query is active.
- Highlighting is presentation only and MUST NOT modify note text.
- All terms use the configured system search-highlight appearance.
- Highlighting MUST update when the query or current note changes.
- Clearing search removes all search highlighting.

### 6.5 Automatic title selection

When the query is non-empty, nvnv determines an automatic title match as follows:

1. Prefer a normalized exact title match.
2. Otherwise consider titles whose normalized value begins with the normalized query.
3. Prefer the candidate with the shortest title.
4. Break remaining ties using the active list sort, then filename.

The automatic match is selected in the list and its body is shown. This selection MUST NOT change the query text.

Body-only matches do not become automatic title matches merely because they are the first result.

### 6.6 Explicit result selection

- Up and Down move through the filtered result list.
- Next Note and Previous Note commands provide equivalent navigation.
- A result chosen through these commands is an explicit selection.
- Explicit selection shows the note body without replacing the query.
- Selection stops at the first or last result; it does not wrap.

### 6.7 Return behavior

Pressing Return in the search field follows this order:

1. If there is an explicitly selected result, open it and focus its editor.
2. Otherwise, if there is an automatic title match, open it and focus its editor.
3. Otherwise, if the trimmed query is non-empty, create a note with that query as its title and an empty body, then focus its editor.
4. Otherwise, do nothing.

Creating from a query MUST clear the query after creation and select the new note.

### 6.8 Escape and deselection

- Escape in search clears the query.
- Clearing the query shows all notes and retains the current note if it still exists.
- Deselect Note removes the current selection and restores the exact query that existed immediately before the current note was explicitly opened.
- If there is no stored prior query, Deselect Note leaves the current query unchanged.

### 6.9 Restored search state

On clean shutdown, nvnv MUST store:

- Query text
- Selected note IDs
- Explicit versus automatic selection state
- Note-list scroll offset
- Current note cursor or selection

On next launch it MUST restore valid state after opening the library. Missing notes are omitted from the selection. An invalid list offset is clamped.

### 6.10 Search execution and SQLite

SQLite accelerates search but does not define search semantics. The application query parser and exact verifier are authoritative for deciding whether a note matches.

For every search-field change, nvnv MUST:

1. Assign the query a monotonically increasing generation number.
2. Parse the field according to section 6.2 without passing raw user input to SQLite FTS syntax.
3. Ask the derived SQLite index for a candidate set when the index is available.
4. Overlay current in-memory state for notes with unsaved edits, pending renames, creations, or deletions.
5. Verify every candidate against the current normalized title and body using the exact substring, phrase, and AND rules from section 6.2.
6. Include any matching dirty note omitted by the last-saved SQLite index and exclude the stale cached form of that note.
7. Sort the verified results using the active note-list sort from section 8.2, never SQLite relevance rank.
8. Apply automatic title selection according to section 6.5.
9. Publish the results only if this is still the newest query generation.

Older search work SHOULD be cancelled when possible and MUST be ignored when cancellation is unavailable. A slow result for an earlier query MUST never replace the results of a later query.

The index MUST NOT change observable query meaning:

- A substring in the middle of a word MUST match.
- One- and two-character terms MUST work.
- Punctuation and SQLite FTS operators in user input MUST be treated according to nvnv's parser, not interpreted as database commands.
- A quoted phrase MUST be verified as a contiguous substring within a title or body; it cannot span the boundary between fields.
- Multiple terms MAY match different fields, but every term MUST match the note.
- Search results MUST remain correct when the index is stale, missing, rebuilding, or unavailable.

When SQLite cannot answer a query completely, nvnv MUST scan the relevant cached rows, in-memory notes, or authoritative files and perform exact verification. Search MAY be slower during a full fallback or rebuild, and the UI SHOULD indicate that indexing is in progress, but it MUST NOT present a known-partial result set as complete.

Recommended implementation: use an SQLite FTS5 trigram index to generate candidates for terms of three or more Unicode characters, then scan the candidate set for exact verification. If every term is shorter than three characters, scan the complete derived note cache. An equivalent implementation is permitted if it satisfies the same behavior and performance requirements.

The cache SHOULD index normalized shadow copies of title and body specifically for candidate generation. Candidate normalization MUST be at least as inclusive as the exact application verifier: normalization differences MUST NOT create false negatives. Original filename and body text remain unchanged and are always used for display and final verification.

After an authoritative file write succeeds, nvnv SHOULD update the affected SQLite search row in the same cache transaction as its hash and file identity. If indexing fails, the file save remains successful, the in-memory overlay remains searchable, and the index is marked for rebuilding.

## 7. Note lifecycle

### 7.1 Create from a title

The only interactive in-application creation flow is defined in section 6.7. The operation MUST:

- Allocate an auxiliary UUID for the current metadata cache.
- Validate and normalize the title.
- Create an empty text file using the default recognized extension.
- Set creation and modification timestamps.
- Add one application-level undo step.
- Queue an immediate persistence operation.
- Select the new note and focus its editor.

Text files created outside nvnv are discovered according to section 13.4 because the library folder is authoritative; that is not a separate in-application creation command.

### 7.2 Rename

Rename is an explicit mode.

- Rename requires exactly one selected note.
- The search field temporarily displays the current title and selects it.
- Search filtering pauses while Rename mode is active.
- Return validates and commits the title.
- Escape cancels and restores the prior query and selection.
- An empty or invalid title is not committed; the current title remains unchanged and an inline error is shown.
- If the requested filename already exists, nvnv proposes the next available numeric suffix before committing.
- A successful rename preserves the note ID, body, creation time, cursor state, and undo history.
- Rename updates `modified_at` and revision.
- The physical file MUST be renamed first. Its new filename stem becomes the committed title.
- A case-only rename on a case-insensitive filesystem MUST use a unique temporary name in the same directory before moving to the requested final name.
- A case-only rename is one logical, journaled operation. Recovery MUST recognize the original, temporary, and final paths and complete or roll back without creating a duplicate note.
- Cache and index updates occur after the rename. A cache failure does not reverse a successful file rename; it marks the cache stale for rebuilding.
- If the physical rename fails, the title and filename remain unchanged.

### 7.3 Edit

- Body edits apply to the one selected note.
- Every edit updates the in-memory note immediately.
- Editor content and visible body excerpts update together.
- Persistence follows section 12.
- Changing to another note MUST NOT discard a pending edit.

### 7.4 Delete

- Delete supports one or several selected notes.
- Confirmation is controlled by a preference and is enabled by default.
- Confirmation names one note or reports the count for several notes.
- Cancelling makes no changes.
- Confirming removes notes from results immediately and records one undoable group.
- Corresponding note files are moved to the system trash or recycle bin when supported.
- If trash is unavailable, nvnv MUST ask before permanent deletion.
- Undo restores note content and auxiliary metadata. It recreates the file atomically if the original trashed file cannot be restored.
- If restoration would collide with a new filename or title, nvnv chooses a safe numeric suffix and explains the change.

### 7.5 Undo and redo

nvnv has two coordinated undo scopes:

- Each open note has an independent editor undo history for body edits.
- The application has an undo history for creation, rename, and deletion.

When the editor has focus, Undo and Redo first operate on that note's body history. In search, the list, or Rename mode, they operate on application-level history.

- Switching notes MUST preserve each note's session undo history.
- Undo and redo are themselves autosaved mutations.
- Undoing creation removes the created note; redo restores it with the same ID.
- Undoing rename restores the prior title and filename.
- Undoing a multi-note deletion restores the group.
- Session undo histories MAY be cleared after a clean application exit.

### 7.6 Cursor memory

- Before a note loses editor focus or selection, its current body selection MUST be recorded.
- Returning to that note restores the selection and scrolls it into view.
- Cursor changes SHOULD be persisted after a short debounce and on every mandatory flush event.
- Cursor persistence does not change the note revision or modification timestamp.

### 7.7 Word count

- Word count is shown only when enabled.
- For exactly one selected note, it shows that note's word count.
- For no selection, it shows no count.
- For multiple selection, it shows the number of selected notes rather than a combined word count.
- Word boundaries SHOULD use the platform's Unicode-aware natural-language tokenizer.
- If no tokenizer is available, a word is a contiguous sequence of letters, numbers, or internal apostrophes.
- The count MAY update after a debounce no longer than 250 ms.

### 7.8 Show in file manager

- This command is available for exactly one selected note.
- It opens the system file manager and selects the note's physical file.
- If the note file is unexpectedly missing, the command starts external-file reconciliation instead of revealing the library folder as if successful.

## 8. Note list

### 8.1 Columns

The list supports these columns:

- Title
- Date Modified
- Date Created

Title MUST remain visible. The two date columns may be independently shown or hidden.

- Users can reorder visible columns.
- Users can resize columns.
- Column order, width, and visibility are stored per library.
- If a stored width cannot fit the current window, it is clamped without destroying the saved preferred width.

### 8.2 Sorting

The user can sort by title, date created, or date modified, ascending or descending.

- Title sorting uses locale-aware, case-insensitive comparison.
- Date sorting uses the full timestamp, not the displayed relative date.
- Ties are resolved by normalized title and then filename.
- Changing sort MUST preserve the selected note and scroll it into view.
- The default sort is date modified, newest first.

### 8.3 Body excerpts

When excerpts are enabled:

- Each row shows at most two visual lines from the body.
- The excerpt starts with the first non-empty body text.
- Runs of whitespace and line breaks are collapsed to a single space for display.
- The underlying body is not changed.
- Editing the current note updates its excerpt without reloading unrelated rows.

When excerpts are disabled, each row uses a compact single-line presentation.

### 8.4 List text size

- A preference controls note-list text size independently of editor text size.
- Supported values MUST include at least 10 through 24 points or the platform-equivalent scalable units.
- Row height and excerpt layout update immediately when the value changes.
- Text MUST remain clipped or elided safely rather than overlapping adjacent rows.

### 8.5 Duplicate filename stems

Files with different recognized extensions may have the same title stem, such as `Project.txt` and `Project.md`.

- When normalized title stems are duplicated, every affected row MUST also display its extension or full filename.
- The extra disambiguation appears only in presentation and MUST NOT change the authoritative title or filename.
- Search, sorting, selection, and keyboard navigation MUST continue to distinguish the rows by filename.
- If the duplication disappears, the list MAY return to its normal title-only presentation.

## 9. Editor behavior

### 9.1 Basic editing

The editor MUST support the platform-standard behavior and shortcuts for:

- Cut
- Copy
- Paste as plain text
- Clear/delete selection
- Select all
- Undo
- Redo

Pasted styled text MUST be reduced to its textual content. Pasting MUST NOT create attachments or formatting attributes.

### 9.2 Find

- Find searches only the current note body.
- The find UI accepts a case-insensitive substring by default.
- Find Next and Find Previous move among matches and wrap at the end or beginning.
- Closing the find UI leaves the last match selected in the editor.
- Find state MAY be remembered per note for the current session.
- Find does not change the global note query.

### 9.3 Indentation

Indent and Outdent operate on every line touched by the current selection.

- With soft tabs disabled, Indent inserts one tab character at each selected line start.
- With soft tabs enabled, Indent inserts spaces to the next configured tab stop.
- Tab width is configurable from 1 through 16 columns and defaults to 4.
- Outdent removes one leading tab or up to one tab width of leading spaces.
- Indent and Outdent are one undo step per invocation.
- If the selection is a caret and Tab-to-indent is enabled, Tab performs Indent at the caret.
- If Tab-to-indent is disabled, Tab advances focus.

### 9.4 New-line indentation

Pressing Return after non-empty text copies the current line's leading tabs and spaces to the new line.

- An otherwise empty indented line followed by Return removes one indentation level instead of creating endless whitespace.
- The copied whitespace is part of the same editor undo operation as the inserted line break.

### 9.5 List continuation

List continuation applies after the current line's leading indentation.

- `- `, `* `, and `+ ` continue using the same bullet.
- A decimal marker such as `7. ` continues as `8. `.
- The generated marker preserves the current line's indentation.
- Pressing Return on an empty continued item removes its marker and ends the list.
- Overflowing the supported integer range leaves the next marker unchanged rather than corrupting text.
- List continuation is plain-text insertion and has no semantic list model.

### 9.6 URLs

- The editor recognizes syntactically valid `http`, `https`, and `mailto` URLs.
- Recognition is visual metadata only and MUST NOT alter stored text.
- Activating a recognized URL uses the platform default handler.
- A URL is opened only after an explicit user action such as Command-click or Open URL at Cursor.
- nvnv MUST ask for confirmation before opening a URL with any unrecognized scheme.

### 9.7 Editor typography

- The editor font family and size are configurable.
- The supported size range MUST include at least 10 through 72 points or platform-equivalent units.
- Changing typography updates every open note without changing note content.
- If the chosen font becomes unavailable, nvnv falls back to the platform default text font and retains the user's preference for possible future use.

## 10. Keyboard command model

On macOS, `Primary` means Command. On other platforms it means the conventional primary accelerator, usually Control. Platform-standard full-screen and window commands MAY retain their native bindings.

| Shortcut | Action |
|---|---|
| `Primary-L` | Focus and select the search field |
| `Escape` | Clear search, cancel Rename, or close Find according to focus |
| `Return` in search | Open explicit/automatic match or create note |
| `Up` / `Down` in search | Select previous/next result |
| `Primary-J` / `Primary-K` | Next/previous result |
| `Primary-D` | Deselect note and restore prior query |
| `Primary-R` | Rename the selected note |
| `Primary-Delete` | Delete selected note or notes |
| `Primary-Z` / `Primary-Shift-Z` | Undo/redo in the active scope |
| `Primary-F` | Find in current note |
| `Primary-G` / `Primary-Shift-G` | Find next/previous |
| `Primary-[` / `Primary-]` | Outdent/indent selected lines |
| `Tab` | Indent or advance focus according to preference and context |
| `Shift-Tab` | Outdent in editor when Tab indents; otherwise move focus backward |
| `Primary-Shift-R` | Show selected note file in file manager |
| `Primary-Option-Left` | Navigate back/snapback |

All commands MUST also be available through accessible menus or controls so shortcut discovery does not depend on this document.

## 11. File-authoritative libraries

A library is one directory selected by the user. Every recognized, valid UTF-8 plain-text file in its root is a note. The files are authoritative; application-managed data is auxiliary and rebuildable.

```text
Library/
  .nvnv/
    index.sqlite3
    settings.json
    journal/
  First Note.txt
  Another Note.txt
```

The `.nvnv` directory is application-managed and MUST NOT be treated as a note source. The library root is non-recursive: supported files in subdirectories are not notes. Hidden files and application temporary files are ignored.

### 11.1 Authoritative note representation

- Every active note MUST have exactly one recognized, valid UTF-8, user-visible plain-text file.
- Only regular files are notes. Symbolic links, aliases, directory links, sockets, devices, and other non-regular entries MUST be ignored and MUST never be followed for reading or writing.
- If two recognized paths resolve to the same hard-linked file identity, nvnv MUST activate only one and report the other as an unsupported duplicate link until the user breaks the link or removes one path.
- The filename without its recognized extension is the note title.
- The entire decoded file content is the note body.
- A note does not exist merely because it has a SQLite row. Without a recognized file or recoverable pending journal entry, it is not an active note.
- Creating, editing, renaming, or deleting a note MUST ultimately create, replace, rename, or trash its physical file.
- When a file and cached SQLite data disagree, the file wins unless an unapplied recovery journal contains newer user input. That case is presented as a recovery conflict.

### 11.2 SQLite index and metadata cache

`.nvnv/index.sqlite3` MUST contain a rebuildable searchable representation of every last-saved valid note file. It MAY also store:

- Auxiliary UUIDs
- Last-seen paths, filesystem identities, hashes, and timestamps
- Cursor and text-selection positions
- Revisions used to order pending local operations
- Note-list and navigation state
- Conflict bases and unresolved conflict state

The cache MUST NOT be the only durable copy of a successfully saved title or body.

- Deleting or losing `index.sqlite3` MUST NOT delete, rename, or rewrite any note file.
- On a missing, corrupt, or incompatible cache, nvnv MUST scan recognized files and build a new cache.
- Rebuilding MAY assign new auxiliary UUIDs and lose cursor, selection, navigation, or undo state.
- Cache loss MUST NOT change titles, bodies, filenames, or filesystem timestamps.
- SQLite cache updates MUST be transactional.
- Search indexes are derived data and MUST be rebuildable from the files.
- A note row MUST be added or refreshed only from a valid authoritative file or from explicit pending recovery state.
- Dirty in-memory editor content MUST NOT be written to the last-saved index before its authoritative file save succeeds; search uses the overlay defined in section 6.10 instead.
- A failed cache update after a successful file operation marks the cache stale; it MUST NOT make nvnv report the file operation as failed.
- SQLite WAL and temporary files MUST remain inside `.nvnv` where supported.

### 11.3 Recognized extensions

- Extension comparison is case-insensitive.
- The default recognized extension and default new-note extension are `.txt`.
- The user may add or remove recognized extensions.
- The default extension MUST always be in the recognized set.
- Changing the recognized set does not rename or delete files.
- A file that ceases to be recognized disappears from the active library after pending edits are flushed; the physical file remains untouched.
- If that extension is recognized again, the file reappears and may receive a new auxiliary UUID.
- Newly created notes use the configured default extension.

### 11.4 Safe filenames and titles

For a title entered inside nvnv, the application MUST construct a filename by:

1. Trimming surrounding whitespace.
2. Replacing path separators, NUL, control characters, and platform-reserved filename characters with `-`.
3. Collapsing repeated replacement characters and trimming forbidden trailing spaces or periods.
4. Rejecting `.` and `..` and avoiding platform-reserved device names.
5. Shortening the stem as needed to remain within platform path limits while retaining the extension.
6. Adding ` 2`, ` 3`, and so on before the extension until the path is unique.

Because the filename is authoritative, its final stem becomes the committed title. Before committing an explicit Create or Rename operation, nvnv MUST show any sanitization, shortening, or collision suffix that materially changes what the user entered and allow cancellation.

Externally created filenames are never silently rewritten merely to satisfy nvnv's preferred naming rules. If the platform can open the path, nvnv uses the exact stem as the logical title and safely escapes problematic characters in the interface.

### 11.5 User-selected library directory

- The user can create a library or open an existing directory.
- nvnv MUST reject a path that is unreadable, unwritable, or inside the system trash.
- Opening an existing folder requires confirmation before nvnv creates `.nvnv` auxiliary data.
- Opening or switching libraries flushes pending edits in the current library first.
- On first open and after cache loss, nvnv scans every recognized root-level file and builds the index.
- Moving a library copies all note files and `.nvnv` recovery material to a staging destination, verifies note counts and content hashes, then switches the authoritative path.
- A cache that fails verification MAY be rebuilt at the destination; note-file verification determines whether the move succeeded.
- The old location is not deleted without explicit confirmation.

### 11.6 Single-writer library lock

At most one nvnv process may hold write access to a library.

- A process MUST acquire an operating-system-backed exclusive lock inside `.nvnv` before replaying recovery data, modifying note files, updating shared auxiliary data, or beginning file reconciliation that can write.
- Lock ownership MUST be determined by the live operating-system lock, not merely by the existence, timestamp, or recorded process ID of a lock file.
- Lock metadata MAY record process ID, application version, host, and acquisition time for diagnostics, but it is not authority.
- The lock is held for the entire writable library session and released only after pending file and journal writes flush during library switch or clean quit.
- Process termination or a crash MUST cause the operating system to release the live lock without requiring the user to delete a stale file manually.

When another nvnv process already owns the lock:

1. The new process SHOULD ask the owning process to bring its library window forward, then exit or close the duplicate window.
2. If the owner cannot be contacted, the user MAY open the library read-only or cancel.
3. The new process MUST NOT offer to steal a lock that is still live.

In read-only mode:

- The interface MUST clearly and persistently identify the library as read-only.
- Search, selection, navigation, and copying remain available.
- Creating, editing, renaming, deleting, undoing mutations, resolving conflicts, replaying recovery entries, and changing library files or shared `.nvnv` state are disabled.
- nvnv MAY read the shared SQLite cache using safe read-only access, but MUST fall back to scanning note files if the cache cannot be read consistently.
- External file changes MAY refresh the read-only view in memory without writing cache state.
- The user may retry acquiring write access after the owning process exits.

## 12. Autosave, atomic writes, and recovery

### 12.1 Mutation pipeline

Every title or body mutation follows this sequence:

1. Update the in-memory note and interface immediately.
2. Mark the note dirty and advance its in-memory revision.
3. Queue a durable recovery-journal entry.
4. Atomically create, replace, or rename the authoritative text file after the autosave delay.
5. Mark the journal entry applied after the file operation succeeds durably.
6. Update auxiliary metadata and the search index.

Step 4 determines whether the note is saved. Failure of step 6 makes the cache stale but does not undo or invalidate the authoritative file operation.

### 12.2 Timing

- Authoritative file autosave begins 750 ms after the most recent edit.
- A continuously edited note MUST be committed no later than 10 seconds after the first uncommitted edit.
- Recovery journal data MUST become durable no later than 2 seconds after the first unjournaled edit.
- Cursor-only changes MAY use a 2-second debounce but MUST flush on note switch and mandatory flush events.
- Multiple dirty notes are saved independently; a failure for one MUST NOT discard another.

### 12.3 Mandatory flush events

Pending journal and authoritative file writes MUST flush before:

- Clean application quit
- Window close when it quits the application
- Operating-system suspension when notification is available
- Library switch
- Library-directory change

If a flush cannot finish, nvnv MUST explain which notes remain pending and offer Retry or Cancel Quit. Forced operating-system termination remains recoverable from the journal.

### 12.4 Authoritative file atomicity

Note-file writes MUST:

1. Write the complete body to a temporary file in the destination filesystem.
2. Flush and close the temporary file.
3. Re-read the destination's current identity and content hash and compare them with the base observed when editing began or the last save completed.
4. If the destination changed, preserve the temporary application version and enter conflict resolution without replacing the destination.
5. Preserve relevant file permissions where possible.
6. Use platform file coordination where available and atomically replace the destination.
7. Flush parent-directory metadata after replacement where the platform provides a durability operation.
8. Preserve the immediately replaced file bytes until the resulting path and content hash are verified.
9. If a concurrent change is detected during replacement, restore or retain the external version, preserve the application version, and enter conflict resolution.
10. After the file replacement succeeds and is verified, attempt to cache the new hash, revision, and file identity.

A partial or failed temporary write MUST NOT replace the last valid note file.

### 12.5 Cache atomicity

- A logical cache update MUST commit in one SQLite transaction.
- A failed cache transaction MUST NOT roll back a successful note-file write, rename, creation, or deletion.
- Cache schema migrations SHOULD be transactional where SQLite permits it.
- A migration failure triggers cache rebuilding from files rather than making the library unavailable.
- Search-index failure marks the cache stale and schedules rebuilding.

### 12.6 Startup recovery

- Recovery runs before the library becomes editable.
- Applied journal entries are discarded safely.
- Unapplied entries are replayed only when their recorded base hash matches the current authoritative file.
- Replaying the same entry more than once MUST have the same result.
- A mismatch creates a recovery conflict and preserves both the authoritative file and journal content.
- After successful file recovery, indexes are checked and rebuilt if stale.
- nvnv MUST report recovered notes once, without interrupting the user for entries that replayed safely.

### 12.7 Corrupt or incompatible auxiliary data

- A missing, corrupt, or newer incompatible SQLite cache MUST be preserved for diagnostics and replaced with a newly built cache.
- Cache incompatibility MUST NOT prevent access to valid recognized note files.
- Malformed settings fall back to documented defaults; the malformed settings file is preserved.
- Journal corruption or an unsupported journal version MUST be reported because it may contain input newer than the files.
- nvnv MUST preserve all authoritative files and recovery material.
- nvnv MUST NOT report a successful file save or recovery until durable completion is verified.

## 13. External file handling

External file handling is part of normal operation because every note is a file.

### 13.1 Watching

- nvnv watches the library root for create, modify, rename, and delete events.
- Duplicate filesystem events SHOULD be debounced for 250 ms.
- `.nvnv`, hidden files, temporary files, and unsupported extensions are ignored.
- On watcher overflow or missed-event notification, nvnv rescans the complete library root.
- A periodic consistency scan MAY detect changes missed by the platform watcher.

### 13.2 Recognizing nvnv's own file operations

Before nvnv creates, replaces, renames, or trashes a note file, it MUST journal a write intent containing:

- Operation identifier and kind
- Original path, file identity, and content hash when present
- Intended final path and content hash when present
- Operation generation and start time

Filesystem events MUST be reconciled against actual post-event file state, not ignored merely because they occurred within a time window.

- If the observed path and hash match a completed write intent, nvnv consumes the event as its own operation and updates the cache without creating a conflict.
- An expected file-identity change caused by atomic replacement is part of the same operation.
- If the observed state differs from the intent, nvnv treats it as a possible external change and performs normal conflict detection.
- A content-identical external rewrite is not a content conflict; nvnv refreshes cached identity and filesystem timestamps.
- Write intents MUST survive a crash until startup recovery confirms their final file state.

### 13.3 File identity

nvnv matches a file to a note using, in order:

1. Stable platform file identity when available
2. Previously recorded path
3. A unique combination of last-seen content hash and timestamps

An ambiguous match MUST NOT be guessed. It is treated as one missing file and one new file until the user resolves it.

### 13.4 Externally created files

- A newly discovered recognized file becomes a note automatically.
- Its title is the filename without its recognized extension.
- Its body is decoded as UTF-8.
- A UTF-8 byte-order mark is accepted and removed from the body.
- Invalid UTF-8 produces an error and leaves the file untouched and unimported.
- File creation and modification dates are used when the platform provides reliable values; otherwise discovery time is used.
- A new auxiliary UUID and cache record are created.

### 13.5 Externally modified files

If the application has no local change since the last common saved revision:

- The file body becomes the note body.
- The note revision advances.
- `modified_at` uses the file modification time when reliable, otherwise detection time.
- The editor, excerpt, word count, and search index update.
- The current cursor is clamped if the new body is shorter.
- The note's editor undo and redo history is cleared.
- nvnv briefly notifies the user that the note changed outside the application and its undo history was cleared.

If both application state and the file changed from the same last-saved hash, nvnv clears the note's editor undo/redo history, shows the same brief notification, and creates a conflict as defined in section 13.8.

### 13.6 Externally renamed files

- A confidently identified external rename updates the cached filename while preserving the current auxiliary UUID.
- The new filename stem immediately becomes the title.
- nvnv MUST NOT rename the file back merely because the new stem is unusual or duplicates the title stem of a file with another extension.
- A rename detected while an application rename is pending creates a conflict.

### 13.7 Externally deleted files

If the note has no local change since the last saved revision:

- Remove it from the active library.
- Record an application-level undo operation.
- Notify the user with an Undo action.
- Undo recreates the text file atomically from the last known body.

If the note has pending or divergent local changes, deletion is a conflict. The conflict choices are Recreate File, Accept Deletion, or Keep Both as a newly named note.

### 13.8 Conflict detection and resolution

A two-sided conflict exists when both the application version and physical file differ from their last common hash, or when concurrent rename/delete operations cannot be ordered safely.

- The affected note becomes read-only until the conflict is resolved.
- Other notes remain fully usable and continue saving.
- nvnv durably preserves the common base, unsaved application version, and observed file version in recovery state.
- The physical file MUST NOT be overwritten while the conflict is unresolved.
- The conflict interface clearly labels each version and its timestamp.
- Closing the conflict interface leaves the note unresolved and read-only; it MUST NOT choose a version implicitly.

The user can choose:

- **Keep App Version:** after confirming the file has not changed again, atomically replace it with the application body. The displaced file version remains in recovery material until resolution completes durably.
- **Use File Version:** re-read the latest file and make it the editor body. The application version remains in recovery material until resolution completes durably.
- **Keep Both:** leave the external file untouched and create the application version as a new note using a safely disambiguated filename.
- **Merge:** edit a proposed result while viewing the base, app, and latest file versions; committing the result writes one new authoritative file revision after another compare-before-replace check.
- **Open File Externally:** open the physical file in its default text editor without resolving the conflict.

The Merge view MAY prefill non-overlapping line changes, but it MUST show unresolved overlaps and MUST NOT commit automatically.

Before Keep App or Merge commits, nvnv MUST compare the current file identity and hash with the version shown in the resolver. If it changed again, the commit stops, the latest file version is loaded, and the user must choose again. No confirmation applies to an unseen file revision.

After Use File, Keep Both, or Merge accepts any external body content, the editor undo/redo history starts empty. Keep App also starts a new undo history after resolution so no pre-conflict operation can later overwrite the resolved file.

If the file changes again while conflict UI is open, nvnv refreshes the file side after warning and retains every previously observed version as recovery material until the conflict resolves.

## 14. Back/snapback navigation

nvnv maintains a session navigation stack.

- Explicitly opening a different note pushes the prior query, selected note, list offset, and editor selection.
- Automatic title selection while merely typing does not push history until the user focuses or edits the automatically selected note.
- Creating a note, following Next/Previous after leaving search, or selecting a row pushes the prior state.
- Back/Snapback restores the most recent valid state and removes it from the stack.
- Deleted or missing notes are skipped.
- Consecutive identical states are coalesced.
- History is session-only and may be empty after relaunch.

## 15. Preferences and defaults

Preferences that affect a library are stored in that library. Typography and keyboard preferences MAY be global, but their scope MUST remain consistent.

| Preference | Default |
|---|---|
| Visible columns | Title and Date Modified |
| Sort | Date Modified, descending |
| Body excerpts | On |
| Word count | On |
| Confirm deletion | On |
| Search highlighting | On |
| List font size | Platform standard small text size |
| Editor font | Platform standard text font, 14 pt |
| Soft tabs | Off |
| Tab width | 4 |
| Tab indents in editor | On |
| Recognized note-file extensions | `.txt` |
| Default note-file extension | `.txt` |

Preference changes that affect visible behavior MUST apply immediately. Invalid numeric values are rejected inline and do not replace the prior valid value.

## 16. Performance and reliability targets

Reference library:

- 10,000 notes
- Median body length: 2 KB
- 95th percentile body length: 100 KB

On supported baseline hardware:

- Warm launch to interactive search: at most 1.5 seconds.
- Search-result update, 95th percentile: at most 150 ms.
- Ordinary note switch, 95th percentile: at most 100 ms.
- Editor keystroke to paint, 95th percentile: at most 50 ms.
- Indexing and external-file scans MUST NOT block typing.
- Memory use MUST remain bounded; nvnv MUST NOT require every full note body to remain rendered or duplicated in memory.

Reliability requirements:

- No edit acknowledged as durably saved may disappear after restart.
- A failed save leaves the previous complete note file readable.
- Crash recovery MUST be tested during create, edit, rename, delete, library movement, and external conflict resolution.
- Every auxiliary structured format MUST have an explicit schema version.

The automated crash matrix MUST terminate the process at least at these boundaries:

- Before and after the recovery journal becomes durable
- During temporary-file writing
- After the temporary file is flushed but before destination comparison
- After comparison but before atomic replacement
- After replacement but before directory metadata is flushed
- After the authoritative file succeeds but before SQLite updates
- At each stage of a case-only rename through its temporary path
- While moving a file to trash

After every crash case, restart MUST yield the complete old version, complete new version, or an explicit conflict containing both. A truncated file or silently lost external version is never acceptable.

## 17. Error behavior

All errors MUST say:

- What failed
- Which note or path was affected when safe to disclose
- Whether existing data remains safe
- What the user can do next

nvnv MUST explicitly handle:

- Library directory missing, moved, unreadable, or unwritable
- Library already locked by another nvnv process
- Disk full
- SQLite cache busy or corrupt
- Unsupported newer cache or journal schema
- Invalid UTF-8 note file
- Failed atomic replace or file rename
- Externally modified, renamed, or deleted file
- Recovery-journal failure
- Filename or title collision

Full note bodies MUST NOT be placed in routine logs. Diagnostics MAY include IDs, paths, revisions, hashes, timestamps, and error codes.

## 18. Acceptance criteria

### 18.1 Search and creation

1. Given notes with query terms split between title and body, multi-token search returns only notes containing every term.
2. A quoted query matches the phrase rather than independent words.
3. Search updates while typing and does not modify any note title.
4. An exact or shortest-prefix title is selected deterministically.
5. Return opens an explicit selection before considering creation.
6. Return creates a uniquely titled empty-body note when no explicit or automatic title match exists.
7. Escape clears search and restores the full sorted list.
8. Restart restores the last valid query, selection, list offset, and cursor.
9. A query matches a substring occurring in the middle of a title or body word.
10. One- and two-character queries return complete, correct results.
11. An unsaved body edit immediately affects search through the in-memory overlay without becoming the last-saved SQLite row.
12. Verified results follow the configured note-list sort rather than SQLite relevance rank.
13. Colons and words such as `AND`, `OR`, and `NOT` are searched literally according to the nvnv parser and cannot inject FTS syntax.
14. A stale, missing, rebuilding, or failed index falls back to exact search and never labels a known-partial result set as complete.
15. When an older slow query completes after a newer query, its generation is discarded and visible results remain those of the newer query.
16. Unicode normalization differences between the candidate index and exact verifier never exclude a true match.
17. No New Note shortcut or command exists; a non-empty unmatched title in the search field followed by Return is the only interactive in-application creation path.

### 18.2 Notes and editing

1. Rename preserves auxiliary identity, rejects empty or invalid titles, and proposes a suffix for filename collisions.
2. Body edits, excerpts, word count, and modification time update coherently.
3. Switching among notes preserves independent editor undo histories and cursor positions.
4. Indent, outdent, inherited whitespace, bullet continuation, numbered continuation, and empty-item termination each produce deterministic plain text.
5. Find operates only inside the current note.
6. Activating a recognized URL opens it only after an explicit user action.

### 18.3 List and navigation

1. Column visibility, order, and width survive restart.
2. Sorting works in both directions for title, created date, and modified date.
3. Selection survives sort and divider changes.
4. The note-list/editor divider position survives restart.
5. Back/Snapback restores the previous query, note, list offset, and editor selection.
6. Multiple selection displays a count, disables body editing, and supports grouped deletion.
7. When two filenames have the same normalized title stem, both rows visibly include enough filename information to distinguish them.

### 18.4 Persistence

1. Clean restart requires no manual Save and preserves all flushed edits.
2. Continuous typing is committed within the hard 10-second deadline.
3. Forced termination after journal flush recovers the latest journaled edit.
4. A SQLite failure after a successful note-file write does not invalidate or reverse that write.
5. A note-file write failure preserves the prior complete file.
6. Corrupt or newer auxiliary data is preserved and rebuilt without overwriting note files.
7. Every crash boundary in section 16 recovers a complete old version, complete new version, or explicit conflict containing both.

### 18.5 File-authoritative storage

1. Every active note has exactly one recognized user-visible plain-text file.
2. Filename stems and file contents are authoritative for titles and bodies.
3. Deleting `index.sqlite3` and relaunching rebuilds search without changing any note file.
4. Renaming a note safely renames its file and normally preserves its auxiliary ID.
5. Unsafe entered titles are presented as safe filenames before commit; filename collisions receive a proposed numeric suffix.
6. Moving a library does not delete the old location without confirmation.
7. Show in File Manager selects the correct note file for every active note.
8. A case-only rename completes as one recoverable logical operation on a case-insensitive filesystem.
9. Symbolic links and non-regular filesystem entries are never opened or modified as notes.
10. Two paths to the same hard-linked file identity are not activated as independently editable notes.
11. Two processes opening the same library never both obtain write access.
12. A second process focuses the existing writer when possible; otherwise it can open a clearly identified read-only view.
13. A read-only process cannot modify note files, shared cache state, journals, or conflicts.
14. Crashing the writer releases the operating-system lock so another process can acquire it without deleting lock files manually.

### 18.6 External changes

1. A new valid UTF-8 recognized file appears as a note with an auxiliary UUID.
2. A one-sided external edit updates the note, search index, excerpt, and word count.
3. An external rename normally preserves auxiliary identity and makes the exact new filename stem authoritative for the title.
4. A clean external deletion removes the note and can be undone by recreating the file.
5. Two-sided edits enter conflict state and never silently overwrite either version.
6. Keep App, Use File, Keep Both, and Merge each produce the documented result.
7. Open File Externally does not resolve or overwrite a conflict.
8. A one-sided external body edit clears that note's undo/redo history and produces a brief notification.
9. Filesystem events caused by nvnv's own verified write intent do not create duplicates or false conflicts.
10. A watcher event that differs from its write intent is treated as a possible external change.
11. Keep App and Merge refuse to commit if the physical file changed after the displayed conflict version was loaded.

## 19. Definition of done

nvnv satisfies this specification when:

- Every MUST requirement has an automated test or a documented manual test.
- A keyboard-only user can complete every retained workflow.
- The acceptance criteria pass with files as the sole authority for note titles and bodies.
- Crash and forced-termination tests demonstrate the stated durability bounds.
- External-file conflict tests demonstrate that neither side is silently lost.
- Performance targets pass against the reference library on documented baseline hardware.
- No tag model, tag index, tag UI, or tag compatibility behavior exists in the implementation.
- Differences required by a target platform are documented rather than accidental.
