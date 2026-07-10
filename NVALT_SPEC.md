# nvALT Reimplementation Specification

Status: Draft derived from the nvALT 2.2.8 source tree  
Purpose: Product, behavior, data, and compatibility specification for recreating nvALT on another platform or technology stack  
Reference implementation: This repository

## 1. How to read this specification

The key words **MUST**, **MUST NOT**, **SHOULD**, **SHOULD NOT**, and **MAY** describe requirement strength.

- **MUST**: required for behavioral parity.
- **SHOULD**: strongly recommended, but may be adapted to the target platform.
- **MAY**: optional or platform-dependent.
- **Legacy**: present in the original application, but dependent on an obsolete service, API, framework, or macOS-specific mechanism.
- **Recommended replacement**: behavior worth preserving through a modern implementation rather than the original dependency.

This is an implementation-oriented behavioral specification, not a requirement to reproduce the original internal Objective-C architecture or serialized database format. A new implementation may use any suitable UI framework, database, search engine, encryption library, or synchronization protocol as long as externally visible behavior is preserved.

## 2. Product definition

nvALT is a keyboard-first personal notes application built around one unusually important interaction: the same field is used to search existing notes and name new notes.

The user should be able to:

1. Summon the application globally.
2. Begin typing immediately.
3. See the note collection filtered as they type.
4. Select and edit an existing note without reaching for a pointer.
5. Press Return to create a note when the entered title does not already identify one.
6. Trust that every edit is saved automatically.

The product is not primarily a document manager or hierarchical notebook. Its organizing model is a flat collection of notes made navigable by full-text search, titles, tags, links, bookmarks, and saved searches.

## 3. Product principles

### 3.1 Keyboard first

Every frequent action MUST be usable without a pointer. Search, note creation, note selection, editing, renaming, tagging, linking, deletion, preview, and navigation all require keyboard paths.

### 3.2 Search and creation are one flow

The application MUST NOT require a separate modal “new note” form for normal creation. Typing in the search/title field filters the collection; pressing Return either selects an existing match or creates a note whose title is the entered text.

### 3.3 No manual save

There is no normal Save command for notes. Edits MUST be persisted automatically and flushed on lifecycle events such as application exit, suspension, window close where applicable, or storage switching.

### 3.4 Plain data and portability

The application SHOULD offer a portable individual-file storage mode. A modern implementation SHOULD use UTF-8 Markdown or plain text as its recommended portable format, even if it also supports richer internal content.

### 3.5 Low-friction linking

Notes SHOULD be linkable by human-readable titles with `[[Wiki Link]]` syntax. Links MUST be navigable, and note-title completion SHOULD make link creation fast.

### 3.6 Resilience

A crash or forced termination SHOULD lose no more than a small, bounded amount of recent input. Writes MUST be atomic or journaled. Corrupt or conflicting external data MUST be surfaced rather than silently overwritten.

## 4. Scope and parity profiles

### 4.1 Core parity

A build reaches **Core parity** when it implements:

- Unified search/create field
- Fast title, body, and tag search
- Note creation, selection, editing, renaming, and deletion
- Automatic persistence
- Flat note list with sorting
- Tags
- `[[Note Links]]`
- Keyboard navigation
- Import and export of plain text/Markdown
- Configurable appearance
- Durable local storage and recovery

### 4.2 Full local parity

A build reaches **Full local parity** when it additionally implements:

- Saved searches and bookmarks
- Multiple storage modes or a compatible portable-file layer
- Rich import/export
- External file monitoring and external-editor support
- Markdown/MultiMarkdown/Textile preview behaviors
- Preview source, locking, printing, and HTML export
- Encryption and credential storage
- Deep links and automation
- Full preference set
- Original keyboard shortcut coverage

### 4.3 Integration parity

A build reaches **Integration parity** when it additionally provides modern equivalents for:

- Cross-device synchronization
- System search indexing
- System share/service integration
- System file tags
- Global activation shortcut
- Menu-bar/tray operation
- External preview application integration

The obsolete Simplenote and Peg.gd protocols do not need to be reproduced to claim modern integration parity. Their user-visible outcomes do.

## 5. Terminology

- **Library**: the complete collection of notes and library-scoped settings.
- **Note**: a titled content item with metadata.
- **Search field**: the unified search/create/title control at the top of the main window.
- **Note list**: the filtered and sorted list of notes.
- **Editor**: the note-body editing surface.
- **Current note**: the single note whose body is displayed in the editor.
- **Selected notes**: one or more selected rows in the note list.
- **Tag**: a user-defined label attached to a note.
- **Note link**: an internal link, normally written `[[Target Title]]`.
- **Bookmark**: a saved navigation state containing a note and search context.
- **Saved search**: a named or persisted query, optionally remembering its last selected note.
- **Portable-file mode**: storage where notes exist as individual files visible to the user and other applications.
- **Database mode**: storage where notes and metadata live in an application-managed database.

## 6. Primary user interface

### 6.1 Main window

The main window MUST contain:

1. A unified search/create/title field.
2. A note list.
3. A note-body editor.
4. An optional word-count display.
5. An optional synchronization or status control.

The original application uses a split view. A recreation MAY use another layout, but search, results, and editor MUST remain simultaneously accessible in the normal desktop/tablet experience.

### 6.2 Focus behavior

- On application activation, focus SHOULD enter the search field unless an explicit editing context is being restored.
- `Command-L` MUST focus the search field on Apple-style platforms. Other platforms SHOULD use the native equivalent while retaining a configurable shortcut.
- `Tab` MUST move between the search field, note list/editor focus targets, unless configured to indent in the editor.
- `Option-Tab` SHOULD always indent in the editor.
- `Shift-Tab` SHOULD move focus backward, except where Markdown link completion explicitly consumes it.
- Escape in the search field MUST clear the current query.
- The editor MUST remember the last selection/caret range for each note during the session and SHOULD persist it between launches.

### 6.3 Layouts

The application MUST support:

- **Vertical layout**: search field, note list, and editor arranged primarily top-to-bottom.
- **Horizontal/widescreen layout**: note list and editor arranged side-by-side.
- Collapsing and restoring the note list.
- Resizing the divider between list and editor.
- Persisting layout, divider position, and collapsed state.

Full-screen editing SHOULD be provided on platforms that support it.

### 6.4 Empty and multi-selection states

- With no current note, the editor MUST show a clear empty state such as “No Note Selected.”
- When multiple notes are selected, the UI MUST indicate the selection count.
- Actions that support multiple notes include delete, tag, export, and print.
- Body editing MUST be disabled or clearly scoped when multiple notes are selected.

## 7. Note data model

Every note MUST have the following logical fields:

| Field | Type | Required | Description |
|---|---|---:|---|
| `id` | UUID/ULID | Yes | Stable identity independent of title and filename |
| `title` | String | Yes | Human-readable title |
| `body` | Rich text or string | Yes | Note content |
| `tags` | Ordered unique strings | Yes | Empty collection when untagged |
| `created_at` | Timestamp | Yes | Creation time |
| `modified_at` | Timestamp | Yes | Last user-visible content/metadata change |
| `cursor_range` | Range | No | Last caret/selection position |
| `filename` | String | Conditional | Portable-file name or exported name |
| `file_format` | Enum | Conditional | Plain text, RTF, HTML, or modern equivalent |
| `file_encoding` | Encoding identifier | Conditional | Defaults to UTF-8 |
| `sync_metadata` | Provider map | No | Provider-specific remote IDs and versions |
| `revision` | Integer/vector | Yes | Monotonic local revision or equivalent |
| `deleted_at` | Timestamp | No | Tombstone marker for sync/recovery |

### 7.1 Title invariants

- A title MUST be non-empty after trimming invalid control characters.
- If an imported note has no usable title, the application MUST assign “Untitled Note” or a localized equivalent.
- Titles SHOULD be unique for predictable search/create behavior and wiki links.
- If exact uniqueness is not enforced, the application MUST define deterministic link and creation behavior for duplicates.
- The recommended modern behavior is to warn and disambiguate duplicate titles while keeping stable IDs internally.

### 7.2 Tag invariants

- Tags MUST be searchable.
- Duplicate tags on a note MUST collapse to one logical tag.
- Tag comparison SHOULD be case-insensitive while preserving the user’s preferred display casing.
- The UI SHOULD autocomplete tags from the library’s existing tag vocabulary.
- The data model SHOULD preserve tag order for display, though filtering semantics treat tags as a set.

### 7.3 Timestamps

- New notes set `created_at` and `modified_at` to the creation time.
- Editing title, body, or tags updates `modified_at`.
- Import SHOULD preserve source creation and modification dates when requested and available.
- The note list SHOULD present friendly relative dates such as Today, Yesterday, and Tomorrow where appropriate.

### 7.4 Deletion model

- User deletion MUST be undoable within the active undo history.
- A sync-capable implementation MUST retain deletion tombstones until all relevant providers have acknowledged them.
- Portable-file deletion SHOULD move files to the system trash/recycle bin where possible.
- Permanent deletion MUST require an explicit action or retention policy.

## 8. Search and filtering

### 8.1 Search sources

The unified query MUST search, case-insensitively, across:

- Note title
- Note body
- Tags

Search MUST update incrementally while the user types.

### 8.2 Token semantics

For parity with the original behavior:

- An unquoted query is split on whitespace and colon characters.
- Every non-empty token MUST match somewhere in the title, body, or tags. Tokens use AND semantics.
- Tokens do not need to match in the same field.
- Matching is substring-based, not whole-word-only.
- Quoted input SHOULD support phrase matching.
- Search SHOULD be Unicode-aware and locale-safe.

Examples:

| Query | Required result behavior |
|---|---|
| `project` | Match notes containing `project` in title, body, or tags |
| `project alpha` | Match notes containing both substrings anywhere across searchable fields |
| `tag:work` | Original parity treats `tag` and `work` as AND tokens; a modern query parser MAY add field operators, but MUST preserve a plain-search mode |
| `"project alpha"` | Match the phrase `project alpha` |

### 8.3 Incremental performance

- Results SHOULD appear within 50 ms for normal libraries and within 150 ms at the 95th percentile for a 10,000-note library on target hardware.
- Extending an existing query SHOULD filter the existing result set when safe.
- Shortening or materially changing the query MUST re-evaluate the complete library.
- Search indexing MUST update after title, body, or tag changes without requiring restart.

### 8.4 Title auto-selection

When enabled:

- If the query is a prefix of a result’s title, the application SHOULD automatically select the shortest suitable title match.
- Auto-selection MUST NOT rename a note merely because the search field changed.
- Title editing is a separate, explicit state entered by Rename, direct title editing, or its shortcut.

### 8.5 Search highlighting

- Matching terms SHOULD be highlighted in the editor and/or note list.
- Highlighting MUST be temporary presentation, not content formatting.
- Highlight color MUST be configurable.
- Highlighting MUST be independently disableable.

### 8.6 Search state restoration

On clean shutdown, the application SHOULD persist:

- Query string
- Current note ID
- Note-list scroll offset
- Current note cursor/selection range

On next launch, it SHOULD restore the state if the referenced note still exists.

## 9. Search/create state machine

The unified field has three conceptual states:

### 9.1 Searching

- Typed text is a query.
- The note list is filtered immediately.
- Up/Down or `Command-J`/`Command-K` changes the selected result.
- Escape clears the query.

### 9.2 Existing note selected

- The selected note’s body is visible.
- The search field may display the active query or selected title depending on target UI design, but the distinction MUST remain clear.
- Typing a new query MUST NOT silently rename the selected note.
- `Command-D` deselects the note and restores the typed search.

### 9.3 Creating

When Return is pressed:

- If the query resolves to an existing note according to the auto-selection rules, open that note for editing.
- Otherwise create a note with the trimmed query as title and an empty body.
- Move focus to the editor.
- Register creation as an undoable action.
- Persist the new note promptly.

If the field is empty, Return SHOULD NOT create an empty-title note.

## 10. Note operations

### 10.1 Create

- Create from the unified field.
- Create from clipboard contents.
- Create from imported data.
- Create through deep-link and automation APIs.
- Create through the platform share/service mechanism.

For body-derived creation, generate a synthetic title from the first meaningful line, capped to a sensible display length. The original uses approximately 36 characters before falling back to or combining with the filename.

### 10.2 Rename

- Rename MUST be explicit.
- Rename MUST preserve note ID, timestamps other than `modified_at`, tags, bookmarks, and sync identity.
- In portable-file mode, rename SHOULD update the filename safely.
- Wiki links targeting the old exact title SHOULD be updated or redirected.
- Rename MUST be undoable.

### 10.3 Delete

- Delete one or multiple selected notes.
- A preference controls confirmation prompts.
- The confirmation identifies the note title or number of notes.
- Deletion MUST be undoable in the current session.
- External edit sessions for deleted notes MUST be closed.
- Bookmarks referring to deleted notes MUST be removed or marked unavailable.

### 10.4 Copy and paste

Support:

- Normal cut/copy/paste
- Copy note deep link/URL
- Paste clipboard as a new note
- Paste a URL as a Markdown link
- Preserve or strip basic styles according to preference
- Plain-text fallback for unsupported rich clipboard formats

### 10.5 Show externally

When available, a note MAY be:

- Revealed in the platform file manager
- Opened in a configured external editor
- Previewed in an external Markdown application

Operations requiring a physical file MUST materialize a safe temporary or portable copy when the library is database-backed.

## 11. Editor behavior

### 11.1 Base editing

The editor MUST support:

- Undo and redo
- Cut, copy, paste, clear, and select all
- Find
- Find and replace
- Find next and previous
- Use selection for find
- Jump to selection
- Spelling checks where the platform supports them
- Text transformations: uppercase, lowercase, capitalize

Each note SHOULD have an independent undo history during the active session.

### 11.2 Rich styles

The original editor supports:

- Plain text style/reset styles
- Bold
- Italic
- Strikethrough

A recreation MAY store Markdown rather than attributed text. If so, the same commands SHOULD apply or remove Markdown delimiters around the selection.

### 11.3 Indentation and lists

- Indent and outdent MUST work on one or more lines.
- With soft tabs enabled, indentation inserts spaces to the next configured tab stop.
- New lines SHOULD inherit leading whitespace.
- Bulleted list markers SHOULD continue automatically.
- Numbered list markers SHOULD continue and increment automatically.
- Entering an empty continued-list item SHOULD end the list.

### 11.4 Automatic pairing

When enabled, typing an opening delimiter SHOULD insert its closing delimiter and place the caret between them. At minimum consider:

- Parentheses
- Square brackets
- Curly braces
- Quotes
- Markdown link/image delimiters where applicable

Typing a closing delimiter when the caret is immediately before an auto-inserted one SHOULD move over it rather than duplicate it.

### 11.5 URLs

- URL recognition SHOULD be configurable.
- Recognized URLs SHOULD be clickable without altering their stored text.
- Activating a URL opens it with the platform default handler.
- Activating an internal nvALT link routes inside the application.

### 11.6 Right-to-left text

- A library or editor preference MUST permit right-to-left paragraph direction.
- Direction changes MUST update active and newly opened notes.
- Stored text MUST remain valid Unicode independent of presentation direction.

### 11.7 Markdown completion mode

When enabled, editing shortcuts operate on Markdown syntax rather than rich attributes. The original behavior includes:

- Bold command toggles `**selection**`.
- Italic command toggles `*selection*`.
- Heading level can be increased or decreased with keyboard commands.
- Blockquote markers can be added or removed from selected paragraphs.
- Link brackets and URL destinations can be stepped through with Tab/Shift-Tab.
- Insert Link creates Markdown link syntax around the selection or caret.

A modern implementation SHOULD define these transformations with deterministic, testable rules and avoid corrupting partially written Markdown.

## 12. Internal note links

### 12.1 Syntax

The canonical human-readable syntax is:

```text
[[Target Note Title]]
```

The parser MUST recognize a complete pair of double brackets and treat the enclosed text as a title reference.

### 12.2 Resolution

- Exact case-insensitive title match has priority.
- If no exact match exists, activating the link SHOULD place its text into the search/create field.
- The user MAY create the missing target by pressing Return.
- If duplicate titles exist, resolution MUST be deterministic and the UI SHOULD offer disambiguation.

### 12.3 Completion

- While typing inside `[[...]]`, the editor SHOULD suggest existing note titles by prefix.
- The shortest appropriate title match SHOULD be selected first.
- Completion MUST be disableable.

### 12.4 Rename handling

Recommended behavior:

- Exact wiki links to a renamed title are rewritten transactionally.
- ID-based deep links remain valid without rewriting.
- Failed rewrites are reported and can be retried.

### 12.5 Navigation history

- Following an internal link SHOULD push the prior note and search state onto a back stack.
- A Back/Snapback action SHOULD restore that state.
- History is session-scoped unless explicitly persisted.

## 13. Tags

### 13.1 Editing

- Tags can be added, removed, or replaced on one note.
- Tags can be applied to multiple selected notes.
- A multi-note tag editor SHOULD initially show tags common to every selected note.
- Tag editing SHOULD support completion.
- Direct editing in the note-list tag column SHOULD be supported on desktop.

### 13.2 Search and display

- Tags are part of ordinary full-text search.
- Tags SHOULD display as visually distinct chips/blocks in the note list.
- A tag filter MAY be offered in addition to free-text search.

### 13.3 File-system tags

On platforms with file tags:

- Portable note files MAY mirror application tags to system file tags.
- Import SHOULD read existing system tags.
- Switching to system tags must warn if conversion is destructive or one-way.
- External tag changes SHOULD be reconciled using the same conflict policy as external content changes.

## 14. Bookmarks

A bookmark stores:

- Stable note ID
- Search string at creation time
- Optional keyboard key equivalent
- Display description

Required behavior:

- Add the current note to bookmarks.
- Restore a bookmark’s search and note selection.
- Remove one bookmark.
- Remove all bookmarks with confirmation.
- Reorder bookmarks.
- Show or hide a bookmark-management window/panel.
- Remove or invalidate bookmarks whose note is deleted.

The original supports at most 26 bookmarks to map them to letter shortcuts. A recreation MAY remove this limit if it preserves shortcut behavior for the first 26.

## 15. Saved searches

A saved search stores:

- Query string
- Optional last-selected note ID
- Display order
- Whether to remember the last selected note

Required behavior:

- Save the current non-empty query.
- Restore a saved query.
- Optionally restore the note last selected under that query.
- Rename/edit the saved query.
- Reorder saved searches.
- Remove one or all saved searches.
- Expose saved searches in a menu or navigation surface.

The original effectively limits the menu to 17 saved searches. A recreation MAY remove this limit.

## 16. Note list

### 16.1 Columns

Desktop implementations MUST support these logical columns:

- Title
- Tags
- Date Modified
- Date Added

Users MUST be able to:

- Show or hide columns
- Reorder visible columns
- Resize columns
- Sort by a column
- Reverse sort direction

At least one column, normally Title, MUST remain visible.

### 16.2 Default list configuration

The original defaults are:

- Visible columns: Title and Date Modified
- Sort column: Date Modified
- Sort direction: newest first
- Note-body previews: enabled
- Grid lines: enabled
- Alternating rows: disabled

### 16.3 Body previews

- The Title row MAY include a one- or multi-line excerpt of the note body.
- Body previews MUST be disableable.
- Editing a note SHOULD update its visible preview without reloading unrelated rows.
- Horizontal layout MAY combine title, tags, and preview into a unified row.

### 16.4 Word count

- A toggle controls word-count visibility.
- For one selected note, show that note’s count.
- For multiple selected notes, the implementation MAY show a total or selection count, but behavior must be documented.
- Count updates SHOULD be debounced while typing.

## 17. Persistence and autosave

### 17.1 Save contract

- Note changes MUST be queued immediately when title, body, tags, or relevant metadata change.
- The original implementation writes approximately 2.7 seconds after the most recent edit and guarantees a write no later than 15 seconds after the first pending edit.
- A recreation SHOULD use a shorter debounce, such as 300–1000 ms, while retaining a hard maximum flush deadline no greater than 15 seconds.
- Pending data MUST flush on application shutdown, suspension, library switch, storage-mode switch, or explicit synchronization.

### 17.2 Atomicity

- Database writes MUST be transactional.
- File writes MUST use temporary-file-plus-atomic-replace semantics where supported.
- Partial writes MUST NOT replace the last valid version.
- The application SHOULD fsync or use the database’s durability guarantees according to a documented policy.

### 17.3 Journal and recovery

- The system SHOULD maintain a write-ahead log, revision log, or equivalent crash-recovery mechanism.
- Each note mutation and deletion SHOULD have a monotonic revision.
- On startup, unapplied journal entries MUST be replayed or presented for recovery.
- Recovery MUST be idempotent.
- If recovery cannot safely complete, preserve both the last valid database and recovery material.

### 17.4 Backups

The original relies mostly on atomic storage/journaling. A new implementation SHOULD additionally provide:

- Automatic rolling backups
- A documented retention policy
- Exportable full-library backup
- Restore preview before destructive replacement
- Optional version history per note

These are recommended enhancements, not strict original parity.

## 18. Storage modes

### 18.1 Database mode

- All notes and metadata are stored in one application-managed database or package.
- Database mode supports encryption.
- It MUST preserve rich content if rich editing is enabled.
- It MUST retain IDs, tags, timestamps, bookmarks, searches, cursor positions, preferences, and sync metadata.

Recommended modern storage: SQLite with transactional migrations, FTS indexing, and a versioned schema.

### 18.2 Portable-file mode

The original supports individual:

- Plain-text files
- RTF files
- HTML files

A new implementation SHOULD prioritize Markdown/plain UTF-8 files and MAY additionally support RTF/HTML.

Portable-file requirements:

- One user-visible file per note.
- Filename derived from title and made unique safely.
- Configurable recognized extensions.
- Configurable default extension.
- Configurable recognized file type identifiers where the platform exposes them.
- External modifications are detected and imported.
- Renaming a note safely renames its file.
- Deleting a note moves or removes its file according to platform convention.
- Tags and stable IDs require sidecar metadata, extended attributes, front matter, or a library index.
- The metadata strategy MUST be documented and round-trip safely.

### 18.3 Changing storage mode

- Switching from database to files MUST materialize every note before committing the setting.
- Switching from files to database MUST import every note before committing the setting.
- Existing source files MUST NOT be deleted without confirmation.
- Encryption MUST be disabled before switching to unencrypted individual files.
- If migration fails, the prior mode remains authoritative and no partial switch is reported as successful.

### 18.4 Notes directory

- Users can select or relocate the library/notes directory.
- The application MUST reject or warn about unusable, read-only, volatile, or trash/recycle-bin locations.
- It SHOULD detect known synchronization feedback-loop risks, such as combining provider sync with an independently cloud-synced folder.

## 19. External file reconciliation

When portable note files change outside the app:

- Detect create, modify, rename, and delete events.
- Debounce duplicate file-system notifications.
- Match files by stable identity where available, falling back to file identity/path/title.
- Import externally created supported files.
- Update notes changed only externally.
- Write app changes when only the app changed.
- If both changed since the last common revision, report a conflict.

Conflict UI MUST offer appropriate choices:

- Keep app version
- Use file version
- Keep both
- Merge, when a safe text merge is available
- Open file externally for inspection

The application MUST NOT silently overwrite two-sided changes.

## 20. Import

### 20.1 Import entry points

- File picker
- Drag and drop
- Opening supported documents with the app
- Clipboard paste-as-new-note
- Platform share/service action
- Deep-link automation
- URL download

### 20.2 Supported original formats

Full compatibility import SHOULD support:

| Format | Required extraction |
|---|---|
| Plain text | Decode text, preferably UTF-8 with encoding detection/fallback |
| RTF/RTFD | Extract styled text; remove unsupported attachments if necessary |
| HTML | Extract rich text or convert to Markdown |
| Web archive | Extract page content and source URL |
| Microsoft Word `.doc` | Extract text and basic styles |
| Microsoft Word `.docx` | Extract text and basic styles |
| PDF | Extract selectable text; do not promise OCR unless separately implemented |
| CSV | First field is title; remaining non-empty fields form body lines |
| TSV | First field is title; remaining non-empty fields form body lines |
| macOS Stickies database | Convert each sticky to a note, preserving dates where possible |
| Notational Velocity `.blor` | Decrypt with supplied passphrase and import notes |

Unsupported attachments SHOULD be omitted with a report rather than causing the whole import to fail.

### 20.3 Batch and folder import

- Multiple selected files MUST import in one operation.
- Folder import SHOULD process supported files in that folder; recursion policy MUST be explicit.
- Import reports counts for successes, skips, and failures.
- A single bad file MUST NOT abort unrelated files unless the user chooses to stop.

### 20.4 Title derivation

Recommended order:

1. Explicit imported title metadata
2. First meaningful content line
3. Source filename without extension
4. “Untitled Note” plus disambiguator

When both content and filename provide useful but different titles, the implementation MAY combine them, but it must do so consistently.

### 20.5 Date and tag import

- A user option controls preservation of file creation dates.
- Modification dates SHOULD be preserved by default.
- File-system tags SHOULD become note tags.
- Source URLs SHOULD be preserved in metadata and MAY also be inserted visibly at the top of the note.

### 20.6 URL import

For `http`, `https`, and optionally `ftp` URLs:

- Download asynchronously.
- Show progress and cancellation.
- Derive title from supplied link title, page title, or URL.
- Store the source URL.
- Optionally convert HTML to Markdown.
- Optionally apply a readability/article-extraction pass.
- Holding a modifier during drag MAY temporarily invert readability behavior.
- Failures MUST produce a user-readable error and MUST NOT create a misleading successful note.

The original Python Readability/html2text scripts are legacy. Use maintained HTML-to-Markdown and article-extraction libraries.

### 20.7 Clipboard import

Clipboard preference order SHOULD be:

1. Existing note/file references
2. Rich application-native note format
3. RTF/RTFD when style preservation is enabled
4. Web archive or HTML when style preservation is enabled
5. Plain text

Attachments that cannot be represented MUST be removed or imported into an asset store with rewritten links.

## 21. Export

### 21.1 Note export

The original exports:

- Plain text
- RTF
- HTML
- Microsoft Word `.doc`
- Microsoft Word XML/`.docx`

A modern build MUST export plain text and Markdown, SHOULD export HTML and PDF, and MAY provide RTF/DOCX.

### 21.2 Single and batch behavior

- One note opens a save-file workflow.
- Multiple notes open a destination-folder workflow.
- Filenames derive from note titles and selected format.
- Existing destinations require Replace, Don’t Replace, and batch Replace All behavior where relevant.
- One failed note MUST offer Continue or Stop Exporting.
- Export must report partial completion accurately.

### 21.3 Full-library export

A modern implementation SHOULD provide an explicit portable-library export containing:

- Note content
- Stable IDs
- Tags
- Created/modified timestamps
- Link information
- Attachments/assets if supported
- A machine-readable manifest

## 22. Printing

- Print one or multiple selected notes.
- Provide page setup where supported.
- Printed notes SHOULD include a visually distinct title followed by body content.
- Multiple notes SHOULD begin on separate pages or have clear separators.
- Preview printing MUST print rendered markup, not the raw source.
- PDF output MAY be delivered through the platform print system or direct export.

## 23. Markup preview

### 23.1 Modes

The original offers:

- Markdown
- MultiMarkdown
- Textile

The live Markdown path in the final source largely routes through MultiMarkdown. A new implementation MUST support CommonMark or a documented Markdown dialect, SHOULD support MultiMarkdown-compatible features, and MAY retain Textile.

### 23.2 Preview window

- Preview is a separate panel/window or clearly separable pane.
- Preview updates after a short typing debounce.
- Preview SHOULD preserve scroll position when the same note updates.
- Selecting another note updates preview unless it is locked.
- Preview visibility persists between launches.
- Links clicked in preview open externally unless they are application deep links.

### 23.3 Preview source

- Users can switch between rendered output and generated HTML source.
- Source is read-only by default.
- Copying generated source MUST be straightforward.

### 23.4 Locked preview

- Locking pins preview to the current note while the main window navigates elsewhere.
- The locked state is visually clear.
- Unlocking refreshes preview to the current note.
- While locked, note-specific Save/Share operations SHOULD either target the pinned note clearly or be disabled, matching the original’s conservative behavior.

### 23.5 Templates and styles

Preview rendering MUST support a default template and stylesheet. Full parity supports user replacements with placeholders equivalent to:

- `{%title%}`
- `{%content%}`
- `{%style%}`
- `{%support%}` or a platform-neutral assets path

Custom templates MAY include JavaScript, subject to the target platform’s security model. Remote script loading SHOULD be opt-in. Preview content MUST be sandboxed from privileged application APIs.

### 23.6 Preview output

- Save generated HTML/XHTML.
- Choose fragment-only versus embedded-in-template output where applicable.
- Print rendered preview.
- Produce PDF through print/export.

### 23.7 External preview

The original integrates with Marked/Marked 2 by opening a note file and placing live text on a named pasteboard. A modern equivalent MAY:

- Open the portable note file in a configured preview app.
- Stream updates through a supported plugin/API.
- Expose a temporary file that updates atomically.

## 24. Sharing and publishing

The original can publish rendered notes to Peg.gd and copy/open the returned URL. Peg.gd is a legacy dependency.

If publishing is retained, the replacement MUST:

- Ask for confirmation before public upload.
- State the destination and privacy implications.
- Upload title and rendered body over HTTPS.
- Handle authentication securely.
- Copy the resulting URL to the clipboard.
- Offer Open in Browser.
- Report failure without exposing note contents in logs.

Publishing SHOULD be implemented as a provider interface so users can choose a maintained service or self-hosted endpoint.

## 25. Synchronization

### 25.1 Original behavior

The reference app contains a Simplenote integration that synchronizes:

- Note creation
- Body and title updates
- Deletion
- Tags
- Remote IDs and versions

It supports automatic intervals of 5, 10, or 30 minutes, manual sync, cancellation, progress, errors, merge/replace decisions, and waiting for pending uploads before quit.

The original endpoint and authentication flow are legacy and MUST NOT be assumed to work.

### 25.2 Modern sync requirements

Sync SHOULD be provider-based. Each provider defines:

- Authentication
- Capability set
- Remote identifier
- Remote revision/version
- Push/pull operations
- Deletion/tombstone behavior
- Conflict policy
- Rate limits and retry rules

### 25.3 Sync states

At minimum expose:

- Disabled
- Not synchronized yet
- Idle with last-sync timestamp
- Authenticating
- Fetching index
- Downloading
- Creating
- Updating
- Deleting
- Processing
- Error
- Offline

The user can trigger Synchronize Now and stop a running manual synchronization where safe.

### 25.4 First-sync reconciliation

When local and remote collections differ, the application MUST offer clearly explained choices as applicable:

- Merge collections, omitting known duplicates
- Replace local collection from remote
- Replace remote collection from local
- Turn off syncing

Destructive choices MUST show item counts and create a local backup first.

### 25.5 Conflicts

- Compare stable IDs and revisions, not only titles.
- Never use last-write-wins silently when both sides changed user content.
- Offer automatic three-way merge for non-overlapping text edits.
- Otherwise retain both versions or show a conflict resolver.
- Tags SHOULD merge as sets unless one side explicitly removed a tag after the common base.

### 25.6 Credentials

- Credentials and tokens MUST use the platform secure credential store.
- Passwords/tokens MUST NOT be written to ordinary preferences, logs, or exported diagnostics.
- Account changes invalidate cached credentials and require re-verification.

### 25.7 Shutdown

- On quit, pending local writes flush first.
- If uploads are active or queued, the app SHOULD briefly wait and show progress.
- The user MUST be able to force quit after warning.
- A failed upload MUST leave durable retry state for the next launch.

## 26. Security and encryption

### 26.1 Threat model

Encryption protects notes at rest when the device or library files are accessed without the passphrase. It does not protect content while the application is unlocked, from a compromised runtime, or from unencrypted exports and remote providers.

### 26.2 Modern encryption requirements

- Use a maintained authenticated-encryption construction such as AES-256-GCM or XChaCha20-Poly1305.
- Derive keys using Argon2id, scrypt, or a current platform-approved KDF.
- Store a random salt and versioned KDF parameters.
- Never store the raw encryption key in the library.
- Authenticate metadata needed to detect tampering.
- Encrypt journal/recovery data and temporary files containing note content.
- Use cryptographically secure random number generation.
- Support key rotation/passphrase change transactionally.

Do not reproduce the original cryptographic primitives merely for source parity.

### 26.3 User workflow

- Encryption is available in database mode.
- Enabling encryption asks for passphrase and verification.
- Disabling encryption warns that notes will be written in clear text.
- Changing passphrase asks for current, new, and verified new passphrase.
- Users choose “remember in secure credential store” or “ask every time.”
- Users can remove a remembered key/passphrase.
- Incorrect passphrases reveal no partial content.
- Cancelling unlock allows quitting or choosing another library.

### 26.4 Secure input

Where supported, passphrase fields MUST use secure input controls. An optional secure-entry mode for note editing MAY be provided, with a warning that it can interfere with text expansion and accessibility tools.

### 26.5 Locking

A modern implementation SHOULD add:

- Manual Lock command
- Auto-lock after configurable inactivity
- Lock on system sleep or user switch
- Memory clearing on lock where practical

These are recommended enhancements beyond the original UI.

## 27. Deep links and automation

### 27.1 URL schemes

Support a registered application scheme such as `nvalt:`. For compatibility, desktop builds MAY also register `nv:`.

### 27.2 Find/open

Compatible shape:

```text
nvalt://find/<percent-encoded-title-or-query>/?NV=<stable-id>
```

Behavior:

- Prefer stable ID when supplied.
- Fall back to provider remote ID when supported.
- Fall back to title/query search.
- Bring the application forward and reveal the note.
- Push the previous navigation state onto history.

### 27.3 Create

Compatible shape:

```text
nvalt://make/?title=...&txt=...&tags=...
nvalt://make/?title=...&html=...&tags=...
nvalt://make/?url=...&title=...
```

Requirements:

- Percent-decode values safely.
- Accept title plus plain body, HTML body, tags, or URL import.
- Sanitize HTML before conversion/rendering.
- Require confirmation for untrusted callers if creation or download could be abusive.
- Define URL length limits and offer a richer local automation API for large content.

### 27.4 Script automation

The original AppleScript dictionary exposes a `search` command. A recreation SHOULD expose the platform-appropriate equivalent:

- Search with a string
- Create note
- Open note by ID/title
- Read/update note where permission policies allow
- List/search notes for trusted local automation

Automation APIs MUST use stable IDs and document authorization boundaries.

### 27.5 Platform share/service integration

Provide an action equivalent to “New Note from Selection” accepting:

- Plain text
- Rich text
- HTML/web archive where available
- Files
- PDF text where available

The action derives a title, creates the note, and reports failure to the calling platform.

## 28. Global activation and background presence

- A configurable global shortcut SHOULD bring the app forward and focus search.
- Invoking it while the app is active MAY hide/toggle the app, matching original “toggle activation” behavior.
- Desktop builds MAY provide a menu-bar/tray icon.
- Users MAY show or hide the dock/taskbar icon if the platform permits.
- If the normal application icon is hidden, at least one reliable way to reopen preferences and quit MUST remain available.
- A preference controls whether closing the main window quits or leaves the app running.
- Desktop distributions SHOULD provide a user-invoked Check for Updates command and use the target platform’s secure update mechanism.
- The application MUST include an accessible keyboard-shortcut reference and basic first-run help for the search/create interaction.

## 29. Appearance and preferences

### 29.1 Color schemes

Provide:

- Black and white
- Low contrast
- User-defined

The user-defined scheme uses configurable foreground and background colors. Search-highlight color is independently configurable.

### 29.2 Typography

- Configurable editor body font and size
- Configurable note-list text size: Small, Large, or custom
- Bold/italic variants MUST derive safely from the base font
- Changing the base font SHOULD restyle unstyled content without destroying explicit emphasis

### 29.3 Readable width

- Optional maximum editor text width
- Configurable width value
- Center or otherwise present the constrained text region sensibly
- Default original maximum: 660 px when enabled; original default is disabled

### 29.4 List appearance

- Toggle grid lines
- Toggle alternating row colors
- Toggle note-body previews
- Toggle custom versus native scrollbars where relevant

### 29.5 Preferences catalog and original defaults

| Preference | Original default | Scope |
|---|---:|---|
| Auto-select notes by title while searching | On | Global |
| Quit when closing main window | On | Global |
| Confirm note deletion | On | Global |
| List text size | Small system size | Global |
| Show menu-bar icon | Off | Global |
| Show Dock icon | On | Global |
| Make URLs clickable | On | Global |
| Soft tabs | Off in stored defaults; some UI resources show On | Global |
| Tab key indents | On | Global |
| Suggest note-link titles | On | Global |
| Convert imported URLs to Markdown | Off | Global |
| Apply Readability to imported URLs | Off | Global |
| Preserve basic pasted styles | On | Global |
| Check spelling while typing | On | Global |
| Right-to-left | Off | Global |
| Auto-pair delimiters | Off | Global |
| Search highlighting | On | Global |
| Body font | Helvetica 12 | Global/library presentation |
| Foreground | Black | Global/library presentation |
| Background | White | Global/library presentation |
| Constrain readable width | Off | Global |
| Maximum body width | 660 px | Global |
| Grid lines | On | Global |
| Alternating rows | Off | Global |
| Note-body previews in list | On | Global |
| Show word count | On | Global |
| Horizontal layout | Off | Global |
| Preview mode | MultiMarkdown | Global |
| Storage mode | Library-specific | Library |
| Encryption | Off | Library |
| Secure entry | Off | Library |
| Confirm Finder file deletion | Configurable | Library |
| Sync enabled | Off until configured | Library/provider |

Where the historical source and XIB disagree, the recreated product MUST choose one documented default and cover it with tests. Recommended modern defaults are UTF-8 Markdown files or a SQLite database, native scrollbars, soft tabs off, four spaces per soft tab, CommonMark preview, and confirmation for destructive operations.

## 30. Keyboard shortcuts

The target platform MAY translate Command to its primary accelerator key. These are the original core bindings:

| Shortcut | Action |
|---|---|
| `Command-L` | Focus search/title field |
| `Escape` | Clear search |
| `Return` | Select/open result or create note; begin editing |
| `Tab` | Move between fields, or indent according to editor preference |
| `Command-J` | Next note |
| `Command-K` | Previous note |
| `Command-D` | Deselect note and restore search text |
| `Command-Shift-V` | Paste clipboard as a new note |
| `Command-R` | Rename selected note |
| `Command-Delete` | Delete selected note(s) |
| `Command-Shift-T` | Tag selected note(s) |
| `Command-Option-C` | Copy the selected note’s deep link/URL |
| `Command-Option-V` | Paste a Markdown link |
| `Command-G` | Find next |
| `Command-Shift-G` | Find previous |
| `Command-F` | Find in the note body |
| `Command-Option-F` | Find and replace |
| `Command-Return` | Open URL/internal link at insertion point |
| `Command-Left` at body start | Move to title editing |
| `Command-Right` at title end | Move to note body |
| `Command-Shift-D` | Bookmark current note / save context, depending on active menu implementation |
| `Command-P` | Print selected note(s) |
| `Command-E` | Export selected note(s) |
| `Command-Shift-R` | Show selected note file in Finder |
| `Command-[` | Outdent lines |
| `Command-]` | Indent lines |
| `Option-Tab` | Indent |
| `Command-T` | Plain text style |
| `Command-B` | Bold or Markdown bold |
| `Command-I` | Italic or Markdown italic |
| `Command-Y` | Strikethrough |
| `Command-Shift-L` | Insert link |
| `Command-Option-L` | Switch horizontal/vertical layout |
| `Command-Shift-C` | Collapse/expand notes list |
| `Command-Option-1/2/3` | Select black-and-white, low-contrast, or user color scheme |
| `Command-Option-P` | Toggle note-body previews in the list |
| `Command-Control-P` | Toggle markup preview |
| `Command-Control-M` | Preview using Marked |
| `Command-Shift-U` | Toggle generated source view |
| `Command-Option-Shift-L` | Lock/unlock preview |
| `Command-Option-Shift-P` | Print preview/PDF |
| `Command-Shift-S` | Save preview HTML |
| `Command-Shift-M` | Toggle Markdown completion |

Notes:

- Some shortcuts overlap by active context or historical menu implementation.
- A new implementation MUST resolve conflicts consistently and expose all bindings in a shortcut reference.
- Global activation shortcut is user-configurable.
- All fixed shortcuts SHOULD be remappable where the target platform convention supports it.

## 31. Accessibility

A recreation SHOULD meet WCAG 2.2 AA or the target platform’s equivalent accessibility guidance.

Requirements:

- Every control has an accessible name and role.
- Search results announce count changes without excessive interruption.
- Focus order follows search → list → editor → secondary controls.
- Selected note and multi-selection state are announced.
- Color is not the only indicator of selection, sync state, error, or locked preview.
- User colors maintain or warn about inadequate contrast.
- Text respects platform scaling where feasible.
- All pointer actions have keyboard alternatives.
- Reduced-motion settings disable nonessential animations.
- Secure-entry features document their effect on assistive technology.

## 32. Localization

The reference tree contains English, German, French, Italian, European Portuguese, and Chinese resources.

A recreation MUST:

- Externalize user-visible strings.
- Support Unicode titles, bodies, tags, paths, and searches.
- Use locale-aware dates and numbers.
- Avoid assuming left-to-right layout.
- Keep shortcut glyph rendering platform-aware.
- Allow translators to reorder interpolated values.

The product SHOULD launch initially in English if translations are not yet maintained, rather than shipping stale partial translations as complete.

## 33. Error handling

### 33.1 General policy

- Never report success before durable completion.
- Preserve user data on partial failure.
- Use actionable language: what failed, what remains safe, and what can be tried next.
- Technical details MAY be expandable or copied for diagnostics.
- Sensitive content, credentials, encryption keys, and full note bodies MUST NOT enter logs by default.

### 33.2 Important error classes

Explicitly handle:

- Notes directory unavailable or moved
- Permission denied
- Disk full
- File encoding failure
- Externally deleted or modified file
- Database created by a newer incompatible version
- Journal recovery failure
- Incorrect passphrase
- Secure credential store unavailable
- Import parse failure
- Export collision or write failure
- URL unavailable
- Sync authentication failure
- Network offline
- Sync conflict
- Remote deletion or empty account mismatch
- Preview renderer/template error

## 34. Non-functional requirements

### 34.1 Performance targets

Reference test library:

- 10,000 notes
- Median body length 2 KB
- 95th percentile body length 100 KB
- 10 tags per tagged note at the 95th percentile

Targets on supported baseline hardware:

- Warm launch to interactive search: ≤ 1.5 seconds
- Search result update p95: ≤ 150 ms
- Note switch p95: ≤ 100 ms for ordinary notes
- Keystroke-to-paint p95: ≤ 50 ms
- Background indexing must not block typing
- Memory use remains bounded for large notes and libraries

### 34.2 Reliability

- No acknowledged edit may disappear after a successful durable write.
- Crash recovery is tested by terminating the process during create, edit, rename, delete, migration, and sync.
- Storage migrations are transactional and resumable.
- Every persistent format has an explicit schema version.

### 34.3 Privacy

- Local-first operation MUST work without an account.
- Network features are opt-in.
- Telemetry, if any, is opt-in or clearly disclosed and never includes note content.
- URL import and preview MUST defend against malicious documents and local-file exfiltration.
- Rendered HTML runs in a restricted context.

### 34.4 Compatibility

- Use UTF-8 for all newly written plain-text files.
- Normalize newlines only according to a documented cross-platform policy.
- Preserve unknown metadata when safely round-tripping portable files.
- Provide export before any irreversible migration.

## 35. Recommended architecture

This section is advisory.

### 35.1 Components

Separate these concerns:

1. **Domain model**: notes, tags, bookmarks, searches, revisions.
2. **Repository/storage**: database and portable-file adapters.
3. **Search index**: incremental full-text indexing.
4. **Editor**: content editing and command transformations.
5. **Link service**: wiki parsing, completion, resolution, rename updates.
6. **Import/export service**: typed converters and batch reporting.
7. **Preview renderer**: Markdown/Textile conversion and sandboxed display.
8. **Sync engine**: provider-neutral operation queue and reconciliation.
9. **Security service**: key derivation, encryption, locking, credential storage.
10. **Platform adapters**: global shortcut, tray/menu bar, file tags, share actions, scripting.

### 35.2 Suggested persistence schema

At minimum:

```text
notes(
  id, title, body, body_format,
  created_at, modified_at,
  cursor_start, cursor_length,
  filename, file_format, file_encoding,
  revision, deleted_at
)

tags(id, canonical_name, display_name)
note_tags(note_id, tag_id, display_order)
bookmarks(id, note_id, query, display_order, shortcut)
saved_searches(id, query, last_note_id, remember_last_note, display_order)
sync_state(note_id, provider, remote_id, remote_revision, base_revision, payload)
operations(id, note_id, kind, revision, created_at, applied_at, payload)
settings(scope, key, value)
```

Use a content FTS table/index over title, body, and tags. Avoid treating the FTS index as authoritative data.

### 35.3 Command model

Represent user mutations as commands so they can participate in:

- Undo/redo
- Autosave
- Journal/recovery
- Sync operation generation
- Analytics-free diagnostics
- Deterministic tests

### 35.4 Provider interfaces

Keep these replaceable:

- Sync providers
- Publishing providers
- Markdown engines
- Article extraction
- Import/export converters
- Credential stores
- System tag/indexing adapters

## 36. Migration and compatibility strategy

### 36.1 Importing an existing nvALT library

A migration tool SHOULD:

1. Locate the notes directory/database chosen by the user.
2. Copy or snapshot source data before reading.
3. Detect single-database versus individual-file storage.
4. Request passphrase if encrypted.
5. Decode notes, IDs, titles, bodies, tags, timestamps, filenames, and selection metadata.
6. Import bookmarks and saved searches where available.
7. Convert provider metadata only when a current provider can use it.
8. Verify counts and content hashes.
9. Produce a migration report.
10. Leave source data untouched by default.

### 36.2 Fidelity levels

Report migration results separately for:

- Content fidelity
- Formatting fidelity
- Metadata fidelity
- Link fidelity
- Tag fidelity
- Automation/deep-link fidelity
- Sync metadata fidelity

### 36.3 Old encrypted data

Legacy decryption code, if implemented, should exist only in an isolated import tool. After import, data MUST be re-encrypted using the modern scheme.

## 37. Legacy feature disposition

| Original feature | Status | Reimplementation decision |
|---|---|---|
| Simplenote legacy API | Obsolete/uncertain | Preserve sync UX with a current provider API |
| Peg.gd publishing | Obsolete | Replace with pluggable HTTPS publishing or omit |
| Python 2-era Readability/html2text scripts | Obsolete | Replace with maintained libraries |
| WebKit legacy WebView | Obsolete | Use sandboxed current web view |
| Sparkle legacy update feeds | Obsolete | Use target platform update mechanism |
| ODB Editor protocol | Niche/legacy | Retain external-editor outcome via temp files or platform API |
| OpenMeta tags | Legacy | Use native file tags or sidecar metadata |
| BLOR database | Legacy import only | Support in migration tool if needed |
| RTF/RTFD as primary note format | Optional | Prefer Markdown/UTF-8; import/export for compatibility |
| Textile | Optional legacy markup | Implement only if user demand requires it |
| Secure Text Entry for whole editor | Platform-specific | Prefer lock/privacy controls; retain if supported |

## 38. Acceptance criteria

### 38.1 Core search/create

1. Given 10,000 indexed notes, typing a query filters by title, body, and tags within the performance target.
2. Given query tokens `alpha beta`, every result contains both tokens across any searchable fields.
3. Given a query matching an existing title prefix, auto-selection chooses the deterministic shortest suitable match when enabled.
4. Given a unique non-empty query with no selected match, Return creates a note with that title and focuses its body.
5. Editing the query while a note is selected never renames the note.

### 38.2 Editing and persistence

1. Body edits survive clean restart without invoking Save.
2. Forced termination after the debounce or hard flush deadline recovers the edit.
3. Create, rename, edit, tag, and delete are undoable according to the documented undo scope.
4. List preview and modified date update after editing.
5. Cursor position restores when returning to a note.

### 38.3 Linking

1. `[[Existing Title]]` opens the target note.
2. `[[Missing Title]]` searches for the missing title and allows creation.
3. Renaming a note preserves ID links and updates exact wiki links or provides redirects.
4. Back navigation restores the previous note and query.

### 38.4 Tags and organization

1. Adding a tag makes the note discoverable by that tag through ordinary search.
2. Multi-tagging applies changes consistently to all selected notes.
3. Sorting works ascending and descending for title, tags, created date, and modified date.
4. Bookmark restoration restores both query and note.
5. Saved searches optionally restore their last selected note.

### 38.5 Files and migration

1. Portable-file edits made externally are detected.
2. Two-sided changes create a conflict rather than silent overwrite.
3. Storage-mode migration is all-or-nothing.
4. Importing one bad file in a batch does not discard successfully imported notes.
5. Exported UTF-8 Markdown can be read without nvALT-specific software.

### 38.6 Preview

1. Markdown edits update rendered preview after debounce.
2. Preview preserves scroll position for edits to the same note.
3. Locked preview remains on its pinned note while main selection changes.
4. Source view matches the HTML used for rendering.
5. Custom template and stylesheet changes are applied safely.

### 38.7 Security

1. Encrypted libraries reveal no note content without the correct passphrase.
2. Wrong passphrase does not alter the library.
3. Journal, backups governed by encrypted-library policy, and temporary editor files do not leak plaintext.
4. Passphrase change is transactional and old/new passphrase behavior is verified after restart.
5. Secure-store removal causes the next unlock to request credentials.

### 38.8 Sync

1. Offline edits queue durably and upload after reconnection.
2. Remote creates, edits, deletes, and tags reconcile locally.
3. Concurrent edits produce merge or conflict UI, never silent loss.
4. First-sync destructive choices show counts and create a backup.
5. Quit with pending uploads waits, allows override, and retains retry state.

## 39. Suggested delivery phases

### Phase 1: Core local notes

- Note model and durable database
- Main three-part UI
- Unified search/create
- Editor and autosave
- Sorting and basic preferences
- Tags and wiki links
- Plain-text/Markdown import/export

### Phase 2: Power-user parity

- Full keyboard model
- Bookmarks and saved searches
- Multiple selection
- Preview and HTML/PDF output
- Portable-file mode and file watching
- External editor
- Deep links and automation

### Phase 3: Security and migration

- Encrypted libraries
- Credential-store integration
- Crash recovery and backups
- Existing nvALT migration utility
- Rich and legacy importers

### Phase 4: Modern integrations

- Provider-based synchronization
- Share extension/service
- Tray/menu-bar operation and global shortcut
- Native file tags and system indexing
- Optional publishing providers

## 40. Open product decisions

These decisions cannot be inherited safely from the old implementation and should be resolved before development:

1. Is the canonical body representation plain Markdown, rich text, or a hybrid?
2. Is the primary store SQLite, individual Markdown files, or user-selectable?
3. Must duplicate note titles be prohibited, warned about, or fully supported?
4. Which Markdown dialect is canonical?
5. Is Textile required?
6. Which legacy import formats are required for the first release?
7. Is exact nvALT database migration required, or only file-based migration?
8. Which platforms are targets, and which global-shortcut/tray behaviors exist on each?
9. Which current sync provider or self-hosted protocol replaces legacy Simplenote?
10. Are attachments supported? The original mostly strips them, but modern users may expect them.
11. Should note history/versioning be first-class?
12. Should saved searches gain modern field operators while retaining original plain token search?
13. What is the threat model for encryption, backups, sync, and temporary files?
14. How are user-authored preview templates sandboxed?
15. Which original keyboard conflicts should be preserved versus normalized?

## 41. Licensing and provenance considerations

This section flags project-planning issues and is not legal advice.

- The repository includes `COPYING.txt` containing the GNU GPL version 3, while individual files and bundled dependencies contain additional BSD, MIT, Apache, Creative Commons, GPL, and other notices.
- Copying or adapting source code may impose license obligations different from implementing behavior described in this specification. Review the license of every reused file and dependency.
- The original icon is identified in `Acknowledgments.txt` as unavailable for commercial use. Do not reuse the icon or other artwork without confirming permission.
- Do not assume the names nvALT, Notational Velocity, Simplenote, Marked, Readability, Peg.gd, or third-party logos are available for a new product’s branding.
- Replace bundled historical libraries with maintained dependencies and produce a current software-bill-of-materials and attribution file.
- Keep a provenance record for imported code, assets, templates, translations, test fixtures, and protocol implementations.
- Before distributing a closed-source or commercial implementation based on this repository, obtain a qualified license review.

## 42. Traceability to the reference repository

The most relevant source areas for validating this specification are:

- `README.markdown`: product description and nvALT-specific additions
- `en.lproj/MainMenu.xib`: commands, menus, and keyboard bindings
- `en.lproj/Preferences.xib`: global editing and appearance preferences
- `en.lproj/NotationPrefsView.nib`: storage, encryption, and Simplenote preferences
- `en.lproj/*.nvhelp`: core interaction and shortcut documentation
- `AppController.m`: primary UI state, actions, layout, lifecycle, and status behavior
- `AppController_Importing.m`: clipboard, deep-link, URL, and file creation flows
- `LinkingEditor.m`: keyboard editing, Markdown assistance, links, lists, and indentation
- `NotationController.m`: filtering, sorting, autosave scheduling, deletion, recovery, and file coordination
- `NoteObject.m`: note model, search matching, serialization, export, file metadata, links, and external editing
- `GlobalPrefs.m`: preference keys and original defaults
- `NotationPrefs.m`: library storage, encryption settings, file types, and sync accounts
- `AlienNoteImporter.m`: import formats and conversion rules
- `ExporterManager.m`: single and batch export behavior
- `PreviewController.m`: markup rendering, source view, templates, publishing, printing, and HTML save
- `SavedSearchesController.m`: saved-search behavior
- `BookmarksController.m`: bookmark behavior
- `SyncSessionController.m` and `Simplenote*`: synchronization states and reconciliation
- `Notation.sdef`: AppleScript command surface
- `Info.plist`: document types, URL schemes, service integration, and application metadata

## 43. Definition of done

A reimplementation is ready for parity review when:

- Every MUST requirement in its declared parity profile has an automated or documented manual test.
- Data survives crash, restart, migration, and conflict test suites.
- A keyboard-only user can complete the primary workflows.
- Search performance meets the stated target on the reference library.
- Plain-text/Markdown export provides a viable exit path.
- Security-sensitive behavior has undergone independent review.
- Legacy integrations have an explicit replacement, omission, or compatibility plan.
- Differences from the original are recorded in release documentation rather than left accidental.
