# ADR 0004: SQLite and search indexing

- Status: accepted
- Distribution: the SQLite shipped with macOS, linked through `CSQLite`
- Wrapper: a small repository local C-API wrapper
- Index: FTS5 trigram virtual table when the runtime probe succeeds

The ordinary `notes` table and authoritative in-memory verifier always provide
a complete fallback. Raw user queries never enter FTS syntax. Failure or loss
of SQLite can affect performance, never note content or observable semantics.
