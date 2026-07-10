# nvnv Feature Scope

## Core interaction

- Keyboard-first operation throughout the application.
- One search field for searching existing notes and naming new notes.
- Incremental search while typing.
- Search across note titles and bodies.
- Multi-token search using AND semantics.
- Phrase search for quoted text.
- Automatic selection of a matching note title while searching.
- Keyboard navigation through search results.
- Press Return to open a match or create a note from an unmatched query.
- Clear the current search with Escape.
- Deselect the current note and return to the prior search.
- Highlight search matches.
- Restore the last query, selected note, list position, and cursor position after relaunch.
- Automatic saving with no normal Save command.
- Prevent outdated asynchronous searches from replacing newer results.

## Main window and navigation

- A main window containing search, note list, and note editor.
- Vertical layout.
- Resizable split between the note list and editor.
- Persisted divider position.
- Full-screen editing.
- Keyboard focus movement among search, list, and editor.
- Clear empty state when no note is selected.
- Multiple-note selection with a visible selection count.
- Back/snapback navigation that restores the previous note and search context.

## Notes

- Create an empty-body note only by typing its title in the search field and pressing Return.
- Edit a note's body.
- Explicitly rename a note without changing its identity.
- Support case-only filename renames safely.
- Delete one or several notes.
- Optional confirmation before deletion.
- Undo note creation, editing, renaming, and deletion.
- Independent per-note undo history during a session.
- Preserve creation and modification timestamps.
- Remember each note's cursor or text selection.
- Show a note in the system file manager.
- Display a word count.

## Note list

- Display note title.
- Display date modified.
- Display date created.
- Show or hide columns.
- Reorder and resize columns.
- Sort by title, date created, or date modified.
- Reverse the sort direction.
- Show an excerpt of the note body beneath or beside its title.
- Toggle body excerpts.
- Configure note-list text size.
- Disambiguate duplicate filename stems by showing extensions or full filenames.

## Editor

- Cut, copy, paste, clear, and select all.
- Undo and redo.
- Find in a note.
- Indent and outdent one or more lines.
- Optional soft tabs with a configurable tab width.
- Optional use of Tab for indentation.
- Carry leading indentation onto a new line.
- Continue bulleted lists automatically.
- Continue and increment numbered lists automatically.
- End a list from an empty list item.
- Recognize and open URLs.
- Configurable editor font and size.

## Local storage, saving, and recovery

- One authoritative plain-text file per note.
- Plain-text note files.
- User-selectable notes/library directory.
- Configurable recognized and default file extensions.
- Safe filenames derived from note titles.
- Rebuildable SQLite search index and application metadata cache.
- Move deleted note files to the system trash where possible.
- Autosave shortly after editing with a maximum flush deadline.
- Flush pending edits on quit, suspension, library changes, and storage changes.
- Transactional cache/index updates after authoritative file writes.
- Atomic note-file writes.
- Journaled crash recovery.
- Recovery of unapplied edits after a crash.
- Detect and report corrupt or incompatible library data.
- Ignore symbolic links and other non-regular files as notes.
- Prevent multiple nvnv processes from writing to the same library; focus the writer or open read-only.

## External file handling

- Watch note files for external changes.
- Detect externally created, edited, renamed, and deleted files.
- Import newly discovered supported files.
- Reconcile application and external file changes.
- Verify that a file has not changed externally immediately before replacing it.
- Distinguish nvnv's own filesystem events from external changes.
- Detect two-sided edit conflicts instead of silently overwriting data.
- Resolve conflicts by keeping the app version, file version, both versions, or a merged version.
- Open a conflicting file externally for inspection.
- Clear a note's undo history after an external body change and show a brief notification.
