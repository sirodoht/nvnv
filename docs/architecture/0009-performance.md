# ADR 0009: Current performance architecture

- Status: accepted current state
- Scope: library scanning, search, editing, and note-list presentation
- Reference scale: 10,000 notes, with a 2 KB median body and a 100 KB
  95th-percentile body

This document records the performance behavior implemented as of July 2026.
It describes the current code rather than proposing a future design. The
filesystem remains authoritative, SQLite remains disposable, and every fast
path must preserve the exact behavior of its complete fallback.

## Search documents and normalization

The application keeps one `SearchDocument` per loaded note. A search document
contains the note, a normalized title, normalized title bytes, normalized body
bytes, and a bounded presentation excerpt. Search verification operates on the
byte representations so it does not repeatedly normalize complete bodies or
retain an additional normalized body `String`.

ASCII text uses a compact lowercase UTF-8 fast path. Non-ASCII text falls back
to Foundation compatibility normalization with case-, diacritic-, and
width-insensitive folding. Turkish and Azerbaijani locales also use the
Foundation path because ASCII `I` has locale-dependent case behavior there.
Both paths are required to produce the same externally defined search
semantics.

Search results initially omit match ranges. Ranges are computed only for the
selected note when highlighting is needed. Excerpts are computed once with the
search document and reused by list rows.

## Query execution

Every query receives a monotonically increasing generation. Work runs outside
the main actor, observes cancellation while generating candidates and verifying
documents, and publishes only if its generation is still current.

The candidate source is chosen in this order:

1. Reuse the preceding visible result set when the new query is a provably
   monotonic refinement and the search-document generation has not changed.
2. Otherwise ask SQLite FTS5 trigram search for the intersection of candidate
   IDs for normalized terms of at least three characters.
3. Otherwise scan all in-memory search documents. This is also the fallback for
   one- and two-character searches or an unavailable FTS5 trigram index.

Dirty, stale, or not-yet-indexed note IDs are conservatively added to SQLite
candidate sets. The application verifier then applies the complete substring,
phrase, AND, and Unicode rules to every candidate. SQLite never decides whether
a note is an exact match and never controls result ordering.

Candidate sets of 2,000 documents or fewer run immediately. Larger scans wait
100 milliseconds so rapid input can cancel obsolete work before it consumes a
worker or publishes an expensive intermediate list. Incremental refinements
often avoid both the full-library scan and this stabilization delay.

## Editing and list stability

Body edits update the in-memory note and the visible row value immediately.
The edited row deliberately retains its current list position during a typing
burst, including when the list is sorted by modification date. This prevents
each keystroke from moving the active note and rebuilding the sorted result
list.

Search membership, highlighting, and configured ordering are recomputed after
650 milliseconds of editing inactivity. Losing editor focus flushes this
deferred refresh immediately. Journal and save scheduling are independent and
are not delayed by the list refresh.

This means the current list can temporarily have stale search membership or be
out of configured sort order while the user is continuously editing. It differs
from the current product specification statements that an unsaved edit affects
search immediately and that ordinary visible search updates occur within 50
milliseconds. The implementation behavior in this section is the current
state; the product specification and implementation should be reconciled
separately.

The same change that introduced deferred resorting removed word-count state,
calculation, settings, and presentation from the application. Word count is
still described by the product specification but is not part of the current
implementation.

## SQLite candidates

When supported by the macOS SQLite runtime, `note_search` is an FTS5 virtual
table using the trigram tokenizer. Normalized title and body values are indexed
after authoritative file operations succeed.

Eligible query terms are looked up independently and their ID sets are
intersected. Terms shorter than three characters do not restrict the trigram
candidate set because FTS cannot answer them completely; the exact verifier
checks them after candidate generation. If no term is eligible, search falls
back to all in-memory documents.

An unavailable, stale, missing, or failed index can reduce performance but must
not change results. Cache writes are transactional, and a cache failure never
reverses a successful note-file operation.

## Incremental library scans

Library scans enumerate every recognized root-level regular file, but unchanged
files reuse their cached decoded body and hash without reopening or rehashing
the file. Reuse is allowed only when all of these cached fingerprint values are
present and equal to the current `lstat` result:

- device and inode identity;
- file size;
- modification time in seconds and nanoseconds; and
- status-change time in seconds and nanoseconds.

Missing fingerprint data forces a reload, including after migration from an
older cache. A same-size edit with a changed precise modification time reloads.
Restoring the old modification time still reloads because the status-change
time changes. A rename can preserve the cached body through file identity, while
replacement at the same path reloads because its identity or other fingerprint
fields differ.

Changed files are memory-mapped when possible, decoded as UTF-8, normalized to
internal LF line endings, and hashed. Invalid UTF-8 is reported and never hidden
by a previously cached body. The cached fingerprint is only a scan accelerator;
the filesystem remains authoritative.

## Note-list presentation

Note rows use a single composed text value for title, duplicate-filename detail,
and excerpt. Only the first row measures content insets for aligning the column
header; the application does not install geometry readers on every row.

Date strings are shared through a bounded, lock-protected presentation cache
instead of creating formatting work per row render. The cache key is the full
`Date`. All entries and the formatter are invalidated when locale, calendar,
time zone, or the local day changes. The cache clears after 50,000 entries to
keep growth bounded. Sorting always uses full timestamps rather than formatted
strings.

## Verification and measurement

Unit and integration tests currently cover:

- equivalence between full search and incremental refinement;
- conservative refinement eligibility;
- immediate execution for small candidate sets;
- ASCII, Unicode, and mixed-body normalization equivalence;
- retention of only one normalized body representation;
- trigram intersection, Unicode normalization, short-term fallback, and
  conservative inclusion of stale notes;
- unchanged-file reuse and forced reloads for metadata, identity, encoding, and
  cache-migration cases; and
- presentation-date reuse, invalidation, and context changes.

`nvnv-probes --performance` remains a quick cached-search smoke probe.
`nvnv-probes --benchmark` measures release-mode normalization, cached and FTS
searches, SQLite index construction and updates, complete and targeted scans,
and a 50,000-note search load. These are reproducible engine benchmarks rather
than enforcement of the specification's percentile targets. The current suite
does not yet measure the complete UI search path, deferred editing refresh,
note-list rendering, application-launch latency, or memory high-water marks.
