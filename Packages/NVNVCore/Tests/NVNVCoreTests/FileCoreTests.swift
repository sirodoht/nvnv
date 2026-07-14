import CSQLite
import Darwin
import Foundation
import NVNVCore
import Testing

@Suite("File-authoritative library")
struct FileCoreTests {
    @Test func sanitizesAndSuffixesTitles() throws {
        #expect(try FilenamePolicy.sanitizedStem("  A/B::C  ") == "A-B-C")
        #expect(throws: NVNVError.self) { try FilenamePolicy.sanitizedStem(" \n ") }
        try withTemporaryDirectory { root in
            try Data().write(to: root.appendingPathComponent("Meeting.txt"))
            #expect(FilenamePolicy.availableFilename(stem: "Meeting", extension: "txt", in: root) == "Meeting 2.txt")
        }
    }

    @Test func scannerHandlesBOMCRLFAndIgnoresNestedAndSymlink() throws {
        try withTemporaryDirectory { root in
            try Data([0xEF, 0xBB, 0xBF] + Array("one\r\ntwo\r\n".utf8)).write(to: root.appendingPathComponent("Alpha.txt"))
            try FileManager.default.createDirectory(at: root.appendingPathComponent("Nested"), withIntermediateDirectories: true)
            try Data("hidden".utf8).write(to: root.appendingPathComponent("Nested/Hidden.txt"))
            try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("Link.txt").path, withDestinationPath: root.appendingPathComponent("Alpha.txt").path)
            let result = try LibraryScanner().scan(directory: root, recognizedExtensions: ["txt"])
            #expect(result.notes.count == 1)
            #expect(result.notes[0].body == "one\ntwo\n")
            #expect(result.notes[0].lineEnding == .crlf)
        }
    }

    @Test func atomicWriterDetectsExternalChange() async throws {
        try await withTemporaryDirectory { root in
            let repository = FileRepository(libraryURL: root)
            guard case .saved(let metadata) = try await repository.create(filename: "A.txt", body: "one") else {
                Issue.record("create unexpectedly conflicted"); return
            }
            #expect(metadata.fileSize == 3)
            #expect(metadata.identity != nil)
            #expect(metadata.modificationSeconds != nil)
            #expect(metadata.statusChangeSeconds != nil)
            try Data("external".utf8).write(to: root.appendingPathComponent("A.txt"))
            let note = Note(title: "A", body: "app", filename: "A.txt", lastSavedHash: metadata.hash)
            guard case .conflict(let data, _) = try await repository.save(note: note) else {
                Issue.record("external change was overwritten"); return
            }
            #expect(String(data: data, encoding: .utf8) == "external")
            #expect(try String(contentsOf: root.appendingPathComponent("A.txt"), encoding: .utf8) == "external")
        }
    }

    @Test func repositoryCanRecreateADeletedNoteAfterResolution() async throws {
        try await withTemporaryDirectory { root in
            let repository = FileRepository(libraryURL: root)
            guard case .saved(let metadata) = try await repository.create(filename: "A.txt", body: "old") else {
                Issue.record("create unexpectedly conflicted"); return
            }
            try FileManager.default.removeItem(at: root.appendingPathComponent("A.txt"))
            let note = Note(
                title: "A", body: "recreated", filename: "A.txt",
                lastSavedHash: metadata.hash
            )

            guard case .saved = try await repository.create(
                filename: note.filename, body: note.body, lineEnding: note.lineEnding
            ) else {
                Issue.record("recreate unexpectedly conflicted"); return
            }
            #expect(try String(contentsOf: root.appendingPathComponent("A.txt"), encoding: .utf8) == "recreated")
        }
    }

    @Test func cacheCanBeDeletedAndRebuiltWithoutTouchingNotes() throws {
        try withTemporaryDirectory { root in
            let file = root.appendingPathComponent("Truth.txt")
            try Data("body".utf8).write(to: file)
            let before = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            let cacheURL = root.appendingPathComponent("index.sqlite3")
            var cache: SQLiteCache? = try SQLiteCache(url: cacheURL)
            let scanned = try LibraryScanner().scan(directory: root, recognizedExtensions: ["txt"]).notes
            try cache?.replaceAll(with: scanned)
            cache = nil
            try FileManager.default.removeItem(at: cacheURL)
            cache = try SQLiteCache(url: cacheURL)
            try cache?.replaceAll(with: scanned)
            #expect(try Data(contentsOf: file) == Data("body".utf8))
            #expect(try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == before)
            #expect(try cache?.cachedNotes().first?.body == "body")
        }
    }

    @Test func trigramCandidatesNormalizeUnicodeAndFallBackForShortTerms() throws {
        guard SQLiteCache.runtimeSupportsFTS5Trigram() else { return }
        try withTemporaryDirectory { root in
            let cafe = Note(title: "Café notes", body: "Crème brûlée", filename: "Café notes.txt")
            let other = Note(title: "Other", body: "ordinary", filename: "Other.txt")
            let cache = try SQLiteCache(url: root.appendingPathComponent("index.sqlite3"))
            try cache.replaceAll(with: [cafe, other])

            let candidates = try cache.candidateIDs(
                forNormalizedTerms: [TextNormalizer.normalize("CAFÉ")]
            )
            #expect(candidates == [cafe.id])
            #expect(try cache.candidateIDs(
                forNormalizedTerms: [TextNormalizer.normalize("fé")]
            ) == nil)
        }
    }

    @Test func trigramCandidatesIntersectEligibleTerms() throws {
        guard SQLiteCache.runtimeSupportsFTS5Trigram() else { return }
        try withTemporaryDirectory { root in
            let both = Note(title: "Alpha", body: "beta", filename: "Both.txt")
            let alpha = Note(title: "Alpha", body: "only", filename: "Alpha.txt")
            let beta = Note(title: "Other", body: "beta", filename: "Beta.txt")
            let cache = try SQLiteCache(url: root.appendingPathComponent("index.sqlite3"))
            try cache.replaceAll(with: [both, alpha, beta])

            #expect(try cache.candidateIDs(
                forNormalizedTerms: ["alpha", "beta"]
            ) == [both.id])
            #expect(try cache.candidateIDs(
                forNormalizedTerms: ["alpha", "be"]
            ) == [both.id, alpha.id])
        }
    }

    @Test func trigramCandidatesConservativelyIncludeStaleNotes() throws {
        guard SQLiteCache.runtimeSupportsFTS5Trigram() else { return }
        try withTemporaryDirectory { root in
            let stale = Note(title: "Draft", body: "old body", filename: "Draft.txt")
            let cache = try SQLiteCache(url: root.appendingPathComponent("index.sqlite3"))
            try cache.replaceAll(with: [stale])

            let candidates = try cache.candidateIDs(
                forNormalizedTerms: ["unsaved"],
                conservativelyIncluding: [stale.id]
            )
            #expect(candidates == [stale.id])
        }
    }

    @Test func cacheAppliesIncrementalUpsertsAndRemovals() throws {
        try withTemporaryDirectory { root in
            let retained = Note(title: "Retained", body: "old", filename: "Retained.txt")
            let removed = Note(title: "Removed", body: "gone", filename: "Reused.txt")
            let cache = try SQLiteCache(url: root.appendingPathComponent("index.sqlite3"))
            try cache.replaceAll(with: [retained, removed])

            var changed = retained
            changed.body = "new"
            changed.revision += 1
            let replacement = Note(title: "Replacement", body: "fresh", filename: "Reused.txt")
            try cache.applyChanges(upserting: [changed, replacement], removing: [removed.id])

            let cachedByID = Dictionary(uniqueKeysWithValues: try cache.cachedNotes().map { ($0.id, $0) })
            #expect(cachedByID.count == 2)
            #expect(cachedByID[retained.id]?.body == "new")
            #expect(cachedByID[removed.id] == nil)
            #expect(cachedByID[replacement.id]?.body == "fresh")

            if cache.fts5TrigramAvailable {
                #expect(try cache.candidateIDs(forNormalizedTerms: ["gone"]) == [])
                #expect(try cache.candidateIDs(forNormalizedTerms: ["fresh"]) == [replacement.id])
            }
        }
    }

    @Test func unchangedFileReusesCachedBodyWithoutReadingOrHashing() throws {
        try withTemporaryDirectory { root in
            let file = root.appendingPathComponent("Stable.txt")
            try Data("disk body".utf8).write(to: file)
            let scanner = LibraryScanner()
            var cached = try scanner.scan(directory: root, recognizedExtensions: ["txt"]).notes[0]
            cached.body = "body supplied by cache"

            let result = try scanner.scan(
                directory: root, recognizedExtensions: ["txt"], cached: [cached.filename: cached]
            )

            #expect(result.notes[0].body == "body supplied by cache")
            #expect(result.notes[0].lastSavedHash == cached.lastSavedHash)
        }
    }

    @Test func targetedScanReadsOnlyChangedPathsAndRepresentsDeletionByOmission() throws {
        try withTemporaryDirectory { root in
            let changedURL = root.appendingPathComponent("Changed.txt")
            let stableURL = root.appendingPathComponent("Stable.txt")
            try Data("old".utf8).write(to: changedURL)
            try Data("stable".utf8).write(to: stableURL)
            let scanner = LibraryScanner()
            let initial = try scanner.scan(directory: root, recognizedExtensions: ["txt"]).notes
            let cached = Dictionary(uniqueKeysWithValues: initial.map { ($0.filename, $0) })

            try Data("new".utf8).write(to: changedURL)
            let changed = try scanner.scan(
                directory: root, paths: [changedURL], recognizedExtensions: ["txt"], cached: cached
            )
            #expect(changed.notes.count == 1)
            #expect(changed.notes[0].filename == "Changed.txt")
            #expect(changed.notes[0].body == "new")

            try FileManager.default.removeItem(at: changedURL)
            let deleted = try scanner.scan(
                directory: root, paths: [changedURL], recognizedExtensions: ["txt"], cached: cached
            )
            #expect(deleted.notes.isEmpty)
        }
    }

    @Test func targetedScanRecognizesRenameWhenOnlyNewPathIsReported() throws {
        try withTemporaryDirectory { root in
            let original = root.appendingPathComponent("Original.txt")
            let renamed = root.appendingPathComponent("Renamed.txt")
            try Data("body".utf8).write(to: original)
            let scanner = LibraryScanner()
            let cached = try scanner.scan(directory: root, recognizedExtensions: ["txt"]).notes[0]
            try FileManager.default.moveItem(at: original, to: renamed)

            let result = try scanner.scan(
                directory: root, paths: [renamed], recognizedExtensions: ["txt"],
                cached: [cached.filename: cached]
            )
            #expect(result.notes.count == 1)
            #expect(result.notes[0].id == cached.id)
            #expect(result.notes[0].filename == "Renamed.txt")
        }
    }

    @Test func sameSizeChangeWithNewPreciseModificationTimeReloads() throws {
        try withTemporaryDirectory { root in
            let file = root.appendingPathComponent("Changed.txt")
            try Data("one".utf8).write(to: file)
            let scanner = LibraryScanner()
            let cached = try scanner.scan(directory: root, recognizedExtensions: ["txt"]).notes[0]

            try Data("two".utf8).write(to: file)
            try FileManager.default.setAttributes(
                [.modificationDate: cached.modifiedAt.addingTimeInterval(2)], ofItemAtPath: file.path
            )
            let result = try scanner.scan(
                directory: root, recognizedExtensions: ["txt"], cached: [cached.filename: cached]
            )

            #expect(result.notes[0].body == "two")
            #expect(result.notes[0].lastSavedHash != cached.lastSavedHash)
            #expect(result.notes[0].fileIdentity == cached.fileIdentity)
        }
    }

    @Test func sameSizeChangeWithRestoredModificationTimeStillReloads() throws {
        try withTemporaryDirectory { root in
            let file = root.appendingPathComponent("PreservedDate.txt")
            try Data("one".utf8).write(to: file)
            let scanner = LibraryScanner()
            let cached = try scanner.scan(directory: root, recognizedExtensions: ["txt"]).notes[0]

            try Data("two".utf8).write(to: file)
            try setModificationTime(
                of: file, seconds: #require(cached.fileModificationSeconds),
                nanoseconds: #require(cached.fileModificationNanoseconds)
            )
            let result = try scanner.scan(
                directory: root, recognizedExtensions: ["txt"], cached: [cached.filename: cached]
            )

            #expect(result.notes[0].body == "two")
            #expect(result.notes[0].fileModificationSeconds == cached.fileModificationSeconds)
            #expect(result.notes[0].fileModificationNanoseconds == cached.fileModificationNanoseconds)
            #expect(
                result.notes[0].fileStatusChangeSeconds != cached.fileStatusChangeSeconds
                    || result.notes[0].fileStatusChangeNanoseconds != cached.fileStatusChangeNanoseconds
            )
        }
    }

    @Test func renamePreservesIdentityButReplacementAtSamePathReloads() throws {
        try withTemporaryDirectory { root in
            let original = root.appendingPathComponent("Original.txt")
            try Data("old".utf8).write(to: original)
            let scanner = LibraryScanner()
            var cached = try scanner.scan(directory: root, recognizedExtensions: ["txt"]).notes[0]
            cached.body = "cached through rename"

            let renamed = root.appendingPathComponent("Renamed.txt")
            try FileManager.default.moveItem(at: original, to: renamed)
            let renameResult = try scanner.scan(
                directory: root, recognizedExtensions: ["txt"], cached: [cached.filename: cached]
            )
            #expect(renameResult.notes[0].id == cached.id)
            // Renaming changes ctime on macOS, so the authoritative body is re-read.
            #expect(renameResult.notes[0].body == "old")
            #expect(renameResult.notes[0].filename == "Renamed.txt")

            let replacement = root.appendingPathComponent("Replacement.tmp")
            try Data("new".utf8).write(to: replacement)
            try FileManager.default.setAttributes(
                [.modificationDate: renameResult.notes[0].modifiedAt], ofItemAtPath: replacement.path
            )
            #expect(Darwin.rename(replacement.path, renamed.path) == 0)
            let replacementResult = try scanner.scan(
                directory: root, recognizedExtensions: ["txt"],
                cached: [renameResult.notes[0].filename: renameResult.notes[0]]
            )
            #expect(replacementResult.notes[0].body == "new")
            #expect(replacementResult.notes[0].fileIdentity != renameResult.notes[0].fileIdentity)
        }
    }

    @Test func changedInvalidUTF8IsNotMaskedByCachedBody() throws {
        try withTemporaryDirectory { root in
            let file = root.appendingPathComponent("Encoding.txt")
            try Data("abc".utf8).write(to: file)
            let scanner = LibraryScanner()
            let cached = try scanner.scan(directory: root, recognizedExtensions: ["txt"]).notes[0]

            try Data([0xFF, 0xFE, 0xFD]).write(to: file)
            try FileManager.default.setAttributes(
                [.modificationDate: cached.modifiedAt.addingTimeInterval(2)], ofItemAtPath: file.path
            )
            let result = try scanner.scan(
                directory: root, recognizedExtensions: ["txt"], cached: [cached.filename: cached]
            )

            #expect(result.notes.isEmpty)
            #expect(result.issues.count == 1)
            #expect(result.issues[0].message.contains("Invalid UTF-8"))
        }
    }

    @Test func versionOneCacheMigratesAndMissingMetadataForcesReload() throws {
        try withTemporaryDirectory { root in
            let noteFile = root.appendingPathComponent("Legacy.txt")
            try Data("authoritative disk body".utf8).write(to: noteFile)
            let cacheURL = root.appendingPathComponent("legacy.sqlite3")
            try createVersionOneCache(at: cacheURL)

            let cache = try SQLiteCache(url: cacheURL)
            let legacy = try #require(cache.cachedNotes().first)
            #expect(legacy.body == "stale cached body")
            #expect(legacy.fileSize == nil)
            #expect(legacy.fileModificationSeconds == nil)
            #expect(legacy.fileModificationNanoseconds == nil)
            #expect(legacy.fileStatusChangeSeconds == nil)
            #expect(legacy.fileStatusChangeNanoseconds == nil)

            let result = try LibraryScanner().scan(
                directory: root, recognizedExtensions: ["txt"], cached: [legacy.filename: legacy]
            )
            #expect(result.notes[0].body == "authoritative disk body")
            #expect(result.notes[0].fileSize != nil)
        }
    }

    @Test func settingsRepositoryLoadsCurrentSchema() async throws {
        try await withTemporaryDirectory { root in
            let repository = SettingsRepository(url: root.appendingPathComponent("settings.json"))
            var settings = LibrarySettings()
            settings.showExcerpts = false
            settings.editorFontSize = 18
            try await repository.save(settings)

            let loaded = await repository.load()
            #expect(loaded == settings)
        }
    }
}

private func setModificationTime(of url: URL, seconds: Int64, nanoseconds: Int64) throws {
    var times = [
        timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)),
        timespec(tv_sec: Int(seconds), tv_nsec: Int(nanoseconds)),
    ]
    let result = times.withUnsafeMutableBufferPointer { buffer in
        utimensat(AT_FDCWD, url.path, buffer.baseAddress, 0)
    }
    guard result == 0 else {
        throw NSError(
            domain: NSPOSIXErrorDomain, code: Int(errno),
            userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errno))]
        )
    }
}

private func createVersionOneCache(at url: URL) throws {
    var database: OpaquePointer?
    guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
        throw NSError(domain: "FileCoreTests", code: 1)
    }
    defer { sqlite3_close(database) }
    let id = UUID().uuidString
    let sql = """
        CREATE TABLE schema_info(version INTEGER NOT NULL);
        INSERT INTO schema_info(version) VALUES(1);
        CREATE TABLE notes(
          id TEXT PRIMARY KEY, title TEXT NOT NULL, body TEXT NOT NULL,
          normalized_title TEXT NOT NULL, normalized_body TEXT NOT NULL,
          created_at REAL NOT NULL, modified_at REAL NOT NULL,
          cursor_start INTEGER NOT NULL, cursor_length INTEGER NOT NULL,
          revision INTEGER NOT NULL, filename TEXT NOT NULL UNIQUE,
          last_saved_hash TEXT NOT NULL, line_ending TEXT NOT NULL,
          file_identity TEXT
        );
        INSERT INTO notes VALUES(
          '\(id)', 'Legacy', 'stale cached body', 'legacy', 'stale cached body',
          1, 1, 0, 0, 0, 'Legacy.txt', 'old-hash', 'lf', NULL
        );
        """
    var error: UnsafeMutablePointer<CChar>?
    guard sqlite3_exec(database, sql, nil, nil, &error) == SQLITE_OK else {
        let message = error.map { String(cString: $0) } ?? "SQLite setup failed"
        sqlite3_free(error)
        throw NSError(domain: "FileCoreTests", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

private func withTemporaryDirectory<T>(_ operation: (URL) throws -> T) throws -> T {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("nvnv-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: url) }
    return try operation(url)
}

private func withTemporaryDirectory<T>(_ operation: (URL) async throws -> T) async throws -> T {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("nvnv-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: url) }
    return try await operation(url)
}
