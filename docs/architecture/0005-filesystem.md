# ADR 0005: Filesystem writes and watching

- Status: accepted
- Coordination: compare-before-replace repository operations
- Atomicity: sibling temporary file, `fsync`, destination recheck, rename,
  directory `fsync`, and resulting hash verification
- Watching: root directory file-descriptor events followed by a debounced scan

Events are hints; reconciliation examines actual paths and hashes. Journaled
write intents identify self-writes. Event overflow and ambiguity converge by a
complete root scan.
