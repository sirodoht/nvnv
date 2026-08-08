import CSQLite
import Foundation

public final class SQLiteCache: @unchecked Sendable {
    private static let schemaVersion = 4
    private static let searchIndexCompleteKey = "search_index_complete"
    private static let searchIndexSignatureKey = "search_index_signature"
    private var database: OpaquePointer?
    private let lock = NSLock()
    private var searchIndexTrusted = false
    public private(set) var fts5TrigramAvailable = false

    public init(url: URL, readOnly: Bool = false) throws {
        var db: OpaquePointer?
        let flags = readOnly
            ? SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
            : SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unable to open SQLite"
            if let db { sqlite3_close(db) }
            throw NVNVError.cache(message)
        }
        database = db
        do {
            try execute("PRAGMA foreign_keys = ON")
            if !readOnly {
                try execute("PRAGMA journal_mode = WAL")
                try execute("PRAGMA synchronous = FULL")
                try migrate()
            }
            fts5TrigramAvailable = Self.probeTrigram(database: db)
            if !readOnly, fts5TrigramAvailable {
                try execute("CREATE VIRTUAL TABLE IF NOT EXISTS note_search USING fts5(note_id UNINDEXED, title, body, tokenize='trigram')")
            }
        } catch {
            sqlite3_close(db)
            database = nil
            throw error
        }
    }

    deinit { if let database { sqlite3_close(database) } }

    public func cachedNotes() throws -> [Note] {
        try withLock { try cachedNotesUnlocked() }
    }

    public func snapshot() throws -> CacheSnapshot {
        try withLock {
            let notes = try cachedNotesUnlocked()
            let valid = (try? searchIndexIsValidUnlocked(expectedNoteCount: notes.count)) ?? false
            searchIndexTrusted = valid
            return CacheSnapshot(
                notes: notes,
                searchIndexIsValid: valid
            )
        }
    }

    public func replaceAll(with notes: [Note]) throws {
        try withLock {
            try executeUnlocked("BEGIN IMMEDIATE")
            do {
                try executeUnlocked("DELETE FROM notes")
                if fts5TrigramAvailable { try executeUnlocked("DELETE FROM note_search") }
                for note in notes { try upsertUnlocked(note) }
                try markSearchIndexCompleteUnlocked()
                try executeUnlocked("COMMIT")
                searchIndexTrusted = fts5TrigramAvailable
            } catch {
                try? executeUnlocked("ROLLBACK")
                throw error
            }
        }
    }

    public func upsert(_ note: Note) throws {
        try withLock {
            try executeUnlocked("BEGIN IMMEDIATE")
            do {
                try upsertUnlocked(note)
                try executeUnlocked("COMMIT")
            } catch {
                try? executeUnlocked("ROLLBACK")
                throw error
            }
        }
    }

    /// Applies a library delta in one transaction. Removals happen first so a
    /// replacement file can reuse a filename previously owned by another note.
    public func applyChanges(upserting notes: [Note], removing ids: Set<UUID>) throws {
        guard !notes.isEmpty || !ids.isEmpty else { return }
        try withLock {
            try executeUnlocked("BEGIN IMMEDIATE")
            do {
                for id in ids { try removeUnlocked(id: id) }
                for note in notes { try upsertUnlocked(note) }
                try executeUnlocked("COMMIT")
            } catch {
                try? executeUnlocked("ROLLBACK")
                throw error
            }
        }
    }

    /// Reconciles the authoritative filesystem snapshot in one transaction.
    /// Metadata-only changes deliberately avoid rewriting the FTS row.
    public func reconcile(_ reconciliation: CacheReconciliation) throws {
        guard !reconciliation.isEmpty else { return }
        try withLock {
            try executeUnlocked("BEGIN IMMEDIATE")
            do {
                for id in reconciliation.removedIDs { try removeUnlocked(id: id) }
                for note in reconciliation.metadataUpserts { try updateMetadataUnlocked(note) }
                for note in reconciliation.indexedUpserts { try upsertUnlocked(note) }
                try executeUnlocked("COMMIT")
            } catch {
                try? executeUnlocked("ROLLBACK")
                throw error
            }
        }
    }

    public func remove(id: UUID) throws {
        try withLock {
            try executeUnlocked("BEGIN IMMEDIATE")
            do {
                try removeUnlocked(id: id)
                try executeUnlocked("COMMIT")
            } catch {
                try? executeUnlocked("ROLLBACK")
                throw error
            }
        }
    }

    public func candidateIDs(for normalizedTerm: String) throws -> Set<UUID>? {
        try candidateIDs(forNormalizedTerms: [normalizedTerm])
    }

    /// Returns an exact-search candidate superset for the eligible terms.
    ///
    /// Terms shorter than three characters cannot use the trigram index. If no
    /// term is eligible (or trigram FTS is unavailable), `nil` asks the caller
    /// to fall back to scanning every document. Notes whose index row may lag
    /// can be supplied in `conservativeIDs`; they are always retained.
    public func candidateIDs(
        forNormalizedTerms normalizedTerms: [String],
        conservativelyIncluding conservativeIDs: Set<UUID> = [],
        isCancelled: @Sendable () -> Bool = { false }
    ) throws -> Set<UUID>? {
        let eligibleTerms = normalizedTerms.filter { !$0.isEmpty && $0.count >= 3 }
        guard fts5TrigramAvailable, !eligibleTerms.isEmpty else { return nil }
        return try withLock {
            guard searchIndexTrusted else { return nil }
            var intersection: Set<UUID>?
            for term in eligibleTerms {
                if isCancelled() { throw CancellationError() }
                let ids = try candidateIDsUnlocked(for: term, isCancelled: isCancelled)
                if let current = intersection {
                    intersection = current.intersection(ids)
                } else {
                    intersection = ids
                }
                if intersection?.isEmpty == true { break }
            }
            return (intersection ?? []).union(conservativeIDs)
        }
    }

    public static func runtimeSupportsFTS5Trigram() -> Bool {
        var db: OpaquePointer?
        guard sqlite3_open(":memory:", &db) == SQLITE_OK else { return false }
        defer { sqlite3_close(db) }
        return probeTrigram(database: db)
    }

    /// Connection-local SQLite mutation count, primarily useful for proving
    /// that a warm reconciliation performed no database writes.
    public var databaseChangeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return Int(sqlite3_total_changes(database))
    }

    private func migrate() throws {
        try execute("CREATE TABLE IF NOT EXISTS schema_info(version INTEGER NOT NULL)")
        try execute("INSERT INTO schema_info(version) SELECT 1 WHERE NOT EXISTS (SELECT 1 FROM schema_info)")
        let existingVersion = try schemaVersionValue()
        guard existingVersion <= Self.schemaVersion else {
            throw NVNVError.cache("cache schema version \(existingVersion) is newer than supported version \(Self.schemaVersion)")
        }
        try execute("""
            CREATE TABLE IF NOT EXISTS notes(
              id TEXT PRIMARY KEY, title TEXT NOT NULL, body TEXT NOT NULL,
              normalized_title TEXT NOT NULL, normalized_body TEXT NOT NULL,
              created_at REAL NOT NULL, modified_at REAL NOT NULL,
              cursor_start INTEGER NOT NULL, cursor_length INTEGER NOT NULL,
              revision INTEGER NOT NULL, filename TEXT NOT NULL UNIQUE,
              last_saved_hash TEXT NOT NULL, line_ending TEXT NOT NULL,
              file_identity TEXT
            )
            """)
        try addColumnIfNeeded("file_size", declaration: "INTEGER")
        try addColumnIfNeeded("file_mtime_seconds", declaration: "INTEGER")
        try addColumnIfNeeded("file_mtime_nanoseconds", declaration: "INTEGER")
        try addColumnIfNeeded("file_ctime_seconds", declaration: "INTEGER")
        try addColumnIfNeeded("file_ctime_nanoseconds", declaration: "INTEGER")
        try execute("CREATE TABLE IF NOT EXISTS cache_info(key TEXT PRIMARY KEY, value TEXT NOT NULL)")
        if existingVersion < Self.schemaVersion {
            try execute("UPDATE schema_info SET version=\(Self.schemaVersion) WHERE version<>\(Self.schemaVersion)")
        }
    }

    private func schemaVersionValue() throws -> Int {
        let statement = try prepare("SELECT version FROM schema_info LIMIT 1")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw NVNVError.cache("cache schema version is missing")
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func cachedNotesUnlocked() throws -> [Note] {
        let sql = "SELECT id,title,body,created_at,modified_at,cursor_start,cursor_length,revision,filename,last_saved_hash,line_ending,file_identity,file_size,file_mtime_seconds,file_mtime_nanoseconds,file_ctime_seconds,file_ctime_nanoseconds FROM notes ORDER BY filename"
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        var notes: [Note] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else {
                throw NVNVError.cache(
                    database.map { String(cString: sqlite3_errmsg($0)) } ?? "unable to read cached notes"
                )
            }
            guard let id = UUID(uuidString: text(statement, 0)) else { continue }
            notes.append(Note(
                id: id, title: text(statement, 1), body: text(statement, 2),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                modifiedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
                cursorStart: Int(sqlite3_column_int64(statement, 5)),
                cursorLength: Int(sqlite3_column_int64(statement, 6)),
                revision: Int(sqlite3_column_int64(statement, 7)), filename: text(statement, 8),
                lastSavedHash: text(statement, 9), lineEnding: LineEnding(rawValue: text(statement, 10)) ?? .lf,
                fileIdentity: nullableText(statement, 11),
                fileSize: nullableInt64(statement, 12),
                fileModificationSeconds: nullableInt64(statement, 13),
                fileModificationNanoseconds: nullableInt64(statement, 14),
                fileStatusChangeSeconds: nullableInt64(statement, 15),
                fileStatusChangeNanoseconds: nullableInt64(statement, 16)
            ))
        }
        return notes
    }

    private func searchIndexIsValidUnlocked(expectedNoteCount: Int) throws -> Bool {
        guard fts5TrigramAvailable,
              try cacheInfoValueUnlocked(for: Self.searchIndexCompleteKey) == "1",
              try cacheInfoValueUnlocked(for: Self.searchIndexSignatureKey) == searchIndexSignature else {
            return false
        }
        let statement = try prepare("SELECT (SELECT COUNT(*) FROM notes), (SELECT COUNT(*) FROM note_search)")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return false }
        return sqlite3_column_int64(statement, 0) == Int64(expectedNoteCount)
            && sqlite3_column_int64(statement, 1) == Int64(expectedNoteCount)
    }

    private var searchIndexSignature: String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let sqlite = String(cString: sqlite3_libversion())
        return "nvnv-\(TextNormalizer.indexFormatVersion)|\(Locale.current.identifier)|\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)|sqlite-\(sqlite)"
    }

    private func cacheInfoValueUnlocked(for key: String) throws -> String? {
        let statement = try prepare("SELECT value FROM cache_info WHERE key=?")
        defer { sqlite3_finalize(statement) }
        bind(key, to: statement, at: 1)
        return sqlite3_step(statement) == SQLITE_ROW ? text(statement, 0) : nil
    }

    private func setCacheInfoValueUnlocked(_ value: String, for key: String) throws {
        let statement = try prepare("INSERT INTO cache_info(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value")
        defer { sqlite3_finalize(statement) }
        bind(key, to: statement, at: 1)
        bind(value, to: statement, at: 2)
        try stepDone(statement)
    }

    private func markSearchIndexCompleteUnlocked() throws {
        guard fts5TrigramAvailable else { return }
        try setCacheInfoValueUnlocked(searchIndexSignature, for: Self.searchIndexSignatureKey)
        try setCacheInfoValueUnlocked("1", for: Self.searchIndexCompleteKey)
    }

    private func upsertUnlocked(_ note: Note) throws {
        let sql = """
            INSERT INTO notes(id,title,body,normalized_title,normalized_body,created_at,modified_at,cursor_start,cursor_length,revision,filename,last_saved_hash,line_ending,file_identity,file_size,file_mtime_seconds,file_mtime_nanoseconds,file_ctime_seconds,file_ctime_nanoseconds)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET title=excluded.title,body=excluded.body,normalized_title=excluded.normalized_title,
              normalized_body=excluded.normalized_body,created_at=excluded.created_at,modified_at=excluded.modified_at,
              cursor_start=excluded.cursor_start,cursor_length=excluded.cursor_length,revision=excluded.revision,
              filename=excluded.filename,last_saved_hash=excluded.last_saved_hash,line_ending=excluded.line_ending,
              file_identity=excluded.file_identity,file_size=excluded.file_size,
              file_mtime_seconds=excluded.file_mtime_seconds,file_mtime_nanoseconds=excluded.file_mtime_nanoseconds,
              file_ctime_seconds=excluded.file_ctime_seconds,file_ctime_nanoseconds=excluded.file_ctime_nanoseconds
            """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        let strings = [note.id.uuidString, note.title, note.body, TextNormalizer.normalize(note.title), TextNormalizer.normalize(note.body)]
        for (index, value) in strings.enumerated() { bind(value, to: statement, at: Int32(index + 1)) }
        sqlite3_bind_double(statement, 6, note.createdAt.timeIntervalSince1970)
        sqlite3_bind_double(statement, 7, note.modifiedAt.timeIntervalSince1970)
        sqlite3_bind_int64(statement, 8, Int64(note.cursorStart))
        sqlite3_bind_int64(statement, 9, Int64(note.cursorLength))
        sqlite3_bind_int64(statement, 10, Int64(note.revision))
        bind(note.filename, to: statement, at: 11)
        bind(note.lastSavedHash, to: statement, at: 12)
        bind(note.lineEnding.rawValue, to: statement, at: 13)
        if let identity = note.fileIdentity { bind(identity, to: statement, at: 14) }
        else { sqlite3_bind_null(statement, 14) }
        bind(note.fileSize, to: statement, at: 15)
        bind(note.fileModificationSeconds, to: statement, at: 16)
        bind(note.fileModificationNanoseconds, to: statement, at: 17)
        bind(note.fileStatusChangeSeconds, to: statement, at: 18)
        bind(note.fileStatusChangeNanoseconds, to: statement, at: 19)
        try stepDone(statement)

        if fts5TrigramAvailable {
            let delete = try prepare("DELETE FROM note_search WHERE note_id=?")
            bind(note.id.uuidString, to: delete, at: 1)
            try stepDone(delete)
            sqlite3_finalize(delete)
            let insert = try prepare("INSERT INTO note_search(note_id,title,body) VALUES(?,?,?)")
            defer { sqlite3_finalize(insert) }
            bind(note.id.uuidString, to: insert, at: 1)
            bind(TextNormalizer.normalize(note.title), to: insert, at: 2)
            bind(TextNormalizer.normalize(note.body), to: insert, at: 3)
            try stepDone(insert)
        }
    }

    private func updateMetadataUnlocked(_ note: Note) throws {
        let sql = """
            UPDATE notes SET created_at=?,modified_at=?,cursor_start=?,cursor_length=?,revision=?,
              filename=?,last_saved_hash=?,line_ending=?,file_identity=?,file_size=?,
              file_mtime_seconds=?,file_mtime_nanoseconds=?,file_ctime_seconds=?,file_ctime_nanoseconds=?
            WHERE id=?
            """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, note.createdAt.timeIntervalSince1970)
        sqlite3_bind_double(statement, 2, note.modifiedAt.timeIntervalSince1970)
        sqlite3_bind_int64(statement, 3, Int64(note.cursorStart))
        sqlite3_bind_int64(statement, 4, Int64(note.cursorLength))
        sqlite3_bind_int64(statement, 5, Int64(note.revision))
        bind(note.filename, to: statement, at: 6)
        bind(note.lastSavedHash, to: statement, at: 7)
        bind(note.lineEnding.rawValue, to: statement, at: 8)
        if let identity = note.fileIdentity { bind(identity, to: statement, at: 9) }
        else { sqlite3_bind_null(statement, 9) }
        bind(note.fileSize, to: statement, at: 10)
        bind(note.fileModificationSeconds, to: statement, at: 11)
        bind(note.fileModificationNanoseconds, to: statement, at: 12)
        bind(note.fileStatusChangeSeconds, to: statement, at: 13)
        bind(note.fileStatusChangeNanoseconds, to: statement, at: 14)
        bind(note.id.uuidString, to: statement, at: 15)
        try stepDone(statement)
        guard sqlite3_changes(database) == 1 else {
            throw NVNVError.cache("metadata update referenced a missing note")
        }
    }

    private func removeUnlocked(id: UUID) throws {
        let statement = try prepare("DELETE FROM notes WHERE id=?")
        defer { sqlite3_finalize(statement) }
        bind(id.uuidString, to: statement, at: 1)
        try stepDone(statement)
        if fts5TrigramAvailable {
            let fts = try prepare("DELETE FROM note_search WHERE note_id=?")
            defer { sqlite3_finalize(fts) }
            bind(id.uuidString, to: fts, at: 1)
            try stepDone(fts)
        }
    }

    private func candidateIDsUnlocked(
        for normalizedTerm: String,
        isCancelled: @Sendable () -> Bool
    ) throws -> Set<UUID> {
        let statement = try prepare("SELECT note_id FROM note_search WHERE note_search MATCH ?")
        defer { sqlite3_finalize(statement) }
        bind("\"\(normalizedTerm.replacingOccurrences(of: "\"", with: "\"\""))\"", to: statement, at: 1)
        var ids: Set<UUID> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if isCancelled() { throw CancellationError() }
            if let id = UUID(uuidString: text(statement, 0)) { ids.insert(id) }
        }
        return ids
    }

    private static func probeTrigram(database: OpaquePointer?) -> Bool {
        guard let database else { return false }
        let sql = "CREATE VIRTUAL TABLE temp.nvnv_trigram_probe USING fts5(value, tokenize='trigram'); DROP TABLE temp.nvnv_trigram_probe;"
        return sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK
    }

    private func execute(_ sql: String) throws { try withLock { try executeUnlocked(sql) } }

    private func addColumnIfNeeded(_ name: String, declaration: String) throws {
        let statement = try prepare("PRAGMA table_info(notes)")
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            if text(statement, 1) == name { return }
        }
        try execute("ALTER TABLE notes ADD COLUMN \(name) \(declaration)")
    }

    private func executeUnlocked(_ sql: String) throws {
        guard let database else { throw NVNVError.cache("database is closed") }
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(error)
            throw NVNVError.cache(message)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        guard let database else { throw NVNVError.cache("database is closed") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw NVNVError.cache(String(cString: sqlite3_errmsg(database)))
        }
        return statement
    }

    private func stepDone(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw NVNVError.cache(database.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite statement failed")
        }
    }

    private func bind(_ value: String, to statement: OpaquePointer, at index: Int32) {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, index, value, -1, transient)
    }

    private func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
    }

    private func nullableText(_ statement: OpaquePointer, _ column: Int32) -> String? {
        sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : text(statement, column)
    }

    private func nullableInt64(_ statement: OpaquePointer, _ column: Int32) -> Int64? {
        sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, column)
    }

    private func bind(_ value: Int64?, to statement: OpaquePointer, at index: Int32) {
        if let value { sqlite3_bind_int64(statement, index, value) }
        else { sqlite3_bind_null(statement, index) }
    }

    private func withLock<T>(_ operation: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}
