import CSQLite
import Foundation

public final class SQLiteCache: @unchecked Sendable {
    private var database: OpaquePointer?
    private let lock = NSLock()
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
        try withLock {
            let sql = "SELECT id,title,body,created_at,modified_at,cursor_start,cursor_length,revision,filename,last_saved_hash,line_ending,file_identity FROM notes ORDER BY filename"
            let statement = try prepare(sql)
            defer { sqlite3_finalize(statement) }
            var notes: [Note] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let id = UUID(uuidString: text(statement, 0)) else { continue }
                notes.append(Note(
                    id: id, title: text(statement, 1), body: text(statement, 2),
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                    modifiedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
                    cursorStart: Int(sqlite3_column_int64(statement, 5)),
                    cursorLength: Int(sqlite3_column_int64(statement, 6)),
                    revision: Int(sqlite3_column_int64(statement, 7)), filename: text(statement, 8),
                    lastSavedHash: text(statement, 9), lineEnding: LineEnding(rawValue: text(statement, 10)) ?? .lf,
                    fileIdentity: nullableText(statement, 11)
                ))
            }
            return notes
        }
    }

    public func replaceAll(with notes: [Note]) throws {
        try withLock {
            try executeUnlocked("BEGIN IMMEDIATE")
            do {
                try executeUnlocked("DELETE FROM notes")
                if fts5TrigramAvailable { try executeUnlocked("DELETE FROM note_search") }
                for note in notes { try upsertUnlocked(note) }
                try executeUnlocked("COMMIT")
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

    public func remove(id: UUID) throws {
        try withLock {
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
    }

    public func candidateIDs(for normalizedTerm: String) throws -> Set<UUID>? {
        guard fts5TrigramAvailable, normalizedTerm.count >= 3 else { return nil }
        return try withLock {
            let statement = try prepare("SELECT note_id FROM note_search WHERE note_search MATCH ?")
            defer { sqlite3_finalize(statement) }
            bind("\"\(normalizedTerm.replacingOccurrences(of: "\"", with: "\"\""))\"", to: statement, at: 1)
            var ids: Set<UUID> = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let id = UUID(uuidString: text(statement, 0)) { ids.insert(id) }
            }
            return ids
        }
    }

    public static func runtimeSupportsFTS5Trigram() -> Bool {
        var db: OpaquePointer?
        guard sqlite3_open(":memory:", &db) == SQLITE_OK else { return false }
        defer { sqlite3_close(db) }
        return probeTrigram(database: db)
    }

    private func migrate() throws {
        try execute("CREATE TABLE IF NOT EXISTS schema_info(version INTEGER NOT NULL)")
        try execute("INSERT INTO schema_info(version) SELECT 1 WHERE NOT EXISTS (SELECT 1 FROM schema_info)")
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
    }

    private func upsertUnlocked(_ note: Note) throws {
        let sql = """
            INSERT INTO notes(id,title,body,normalized_title,normalized_body,created_at,modified_at,cursor_start,cursor_length,revision,filename,last_saved_hash,line_ending,file_identity)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET title=excluded.title,body=excluded.body,normalized_title=excluded.normalized_title,
              normalized_body=excluded.normalized_body,created_at=excluded.created_at,modified_at=excluded.modified_at,
              cursor_start=excluded.cursor_start,cursor_length=excluded.cursor_length,revision=excluded.revision,
              filename=excluded.filename,last_saved_hash=excluded.last_saved_hash,line_ending=excluded.line_ending,file_identity=excluded.file_identity
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

    private static func probeTrigram(database: OpaquePointer?) -> Bool {
        guard let database else { return false }
        let sql = "CREATE VIRTUAL TABLE temp.nvnv_trigram_probe USING fts5(value, tokenize='trigram'); DROP TABLE temp.nvnv_trigram_probe;"
        return sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK
    }

    private func execute(_ sql: String) throws { try withLock { try executeUnlocked(sql) } }

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

    private func withLock<T>(_ operation: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}
