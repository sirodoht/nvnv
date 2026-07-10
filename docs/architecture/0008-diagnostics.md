# ADR 0008: Diagnostics and redaction

- Status: accepted
- Runtime logging: `os.Logger`, subsystem `app.nvnv`
- Safe fields: note IDs, paths, revisions, hashes, timestamps, error codes
- Prohibited fields: note bodies and recovery payload contents

User errors state what failed, whether existing data is safe, and a next step.
Diagnostics must not serialize note bodies outside the recovery journal, whose
purpose is explicitly to preserve unsaved user input.
