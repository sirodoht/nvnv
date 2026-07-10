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
            guard case .saved(let hash, _, _) = try await repository.create(filename: "A.txt", body: "one") else {
                Issue.record("create unexpectedly conflicted"); return
            }
            try Data("external".utf8).write(to: root.appendingPathComponent("A.txt"))
            let note = Note(title: "A", body: "app", filename: "A.txt", lastSavedHash: hash)
            guard case .conflict(let data, _) = try await repository.save(note: note) else {
                Issue.record("external change was overwritten"); return
            }
            #expect(String(data: data, encoding: .utf8) == "external")
            #expect(try String(contentsOf: root.appendingPathComponent("A.txt"), encoding: .utf8) == "external")
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
