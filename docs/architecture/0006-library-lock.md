# ADR 0006: Exclusive library lock

- Status: accepted
- Mechanism: non-blocking POSIX `flock` on `.nvnv/library.lock`

The file may contain diagnostic metadata, but the live kernel lock is the only
authority. A crash closes the descriptor and releases the lock. A second
process opens the library read-only when it cannot acquire the live lock.
Cross-process activation is best effort through `NSRunningApplication` and is
not used as lock authority.
