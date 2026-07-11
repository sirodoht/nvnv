import Foundation
import NVNVCore

@main
struct NVNVProbes {
    static func main() async throws {
        if CommandLine.arguments.contains("--benchmark") {
            try runBenchmarks()
            return
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nvnv-probes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let auxiliary = root.appendingPathComponent(".nvnv")
        let firstLock = try LibraryLock(auxiliaryDirectory: auxiliary)
        let secondLock = try LibraryLock(auxiliaryDirectory: auxiliary)
        guard firstLock.isWritable, !secondLock.isWritable else { fatalError("exclusive lock probe failed") }

        let repository = FileRepository(libraryURL: root)
        let created = try await repository.create(filename: "Probe.txt", body: "alpha")
        guard case .saved(let hash, _, _) = created else { fatalError("create probe conflicted") }
        let note = Note(title: "Probe", body: "beta", filename: "Probe.txt", lastSavedHash: hash)
        guard case .saved = try await repository.save(note: note) else { fatalError("replace probe conflicted") }

        guard SQLiteCache.runtimeSupportsFTS5Trigram() else { fatalError("SQLite FTS5 trigram unavailable") }
        print("PASS sqlite-fts5-trigram atomic-replace directory-durability library-lock")

        if CommandLine.arguments.contains("--performance") {
            let body = String(repeating: "ordinary cached note text ", count: 80) + " needle"
            let documents = (0..<10_000).map { index in
                SearchDocument(note: Note(title: "Reference Note \(index)", body: body, filename: "Reference Note \(index).txt"))
            }
            let result = measure(iterations: 7, warmups: 1) {
                SearchService.search(SearchQuery("needle"), in: documents, sort: .init()).count
            }
            guard result.checksum == 70_000 else { fatalError("performance search returned incomplete results") }
            print(String(format: "PERF cached-search-10000 %.1fms", result.medianMilliseconds))
        }
    }

    private static func runBenchmarks() throws {
        guard SQLiteCache.runtimeSupportsFTS5Trigram() else { fatalError("SQLite FTS5 trigram unavailable") }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nvnv-benchmark-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let noteCount = 10_000
        let bodyByteCount = 2_048
        print("BENCH config notes=\(noteCount) body_bytes=\(bodyByteCount) samples=7")

        let notes = makeNotes(count: noteCount, bodyByteCount: bodyByteCount)
        let documentBuild = measure(iterations: 7, warmups: 1) {
            notes.map(SearchDocument.init).count
        }
        report("search-document-build", documentBuild)
        let documents = notes.map(SearchDocument.init)
        let documentsByID = Dictionary(uniqueKeysWithValues: documents.map { ($0.id, $0) })

        let broad = measure(iterations: 7, warmups: 1) {
            SearchService.search(SearchQuery("ordinary"), in: documents, sort: .init()).count
        }
        report("search-broad-10000", broad)

        let missing = measure(iterations: 7, warmups: 1) {
            SearchService.search(SearchQuery("term-that-is-never-present"), in: documents, sort: .init()).count
        }
        report("search-missing-10000", missing)

        let cacheURL = root.appendingPathComponent("benchmark.sqlite3")
        let cache = try SQLiteCache(url: cacheURL)
        let indexBuild = try measure(iterations: 1, warmups: 0) {
            try cache.replaceAll(with: notes)
            return notes.count
        }
        report("sqlite-index-build-10000", indexBuild)

        let selective = try measure(iterations: 7, warmups: 1) {
            let ids = try cache.candidateIDs(forNormalizedTerms: ["marker9999"]) ?? []
            // Match the application's current candidate materialization path,
            // including its full dictionary scan before exact verification.
            let candidates = documentsByID.values.filter { ids.contains($0.id) }
            return SearchService.search(SearchQuery("marker9999"), in: candidates, sort: .init()).count
        }
        report("search-selective-fts-10000", selective)

        var changed = notes[noteCount / 2]
        changed.body += " changed"
        changed.revision += 1
        let cacheDelta = try measure(iterations: 7, warmups: 1) {
            try cache.applyChanges(upserting: [changed], removing: [])
            return 1
        }
        report("sqlite-single-note-update", cacheDelta)

        let library = root.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        for note in notes {
            try Data(note.body.utf8).write(to: library.appendingPathComponent(note.filename))
        }
        let scanner = LibraryScanner()
        let initialScan = try measure(iterations: 1, warmups: 0) {
            try scanner.scan(directory: library, recognizedExtensions: ["txt"]).notes.count
        }
        report("filesystem-initial-scan-10000", initialScan)
        let scanned = try scanner.scan(directory: library, recognizedExtensions: ["txt"]).notes
        let cachedByFilename = Dictionary(uniqueKeysWithValues: scanned.map { ($0.filename, $0) })

        let warmScan = try measure(iterations: 7, warmups: 1) {
            try scanner.scan(
                directory: library, recognizedExtensions: ["txt"], cached: cachedByFilename
            ).notes.count
        }
        report("filesystem-warm-scan-10000", warmScan)

        let changedURL = library.appendingPathComponent(notes[noteCount / 2].filename)
        try Data((notes[noteCount / 2].body + " externally changed").utf8).write(to: changedURL)
        let targetedScan = try measure(iterations: 7, warmups: 1) {
            try scanner.scan(
                directory: library, paths: [changedURL], recognizedExtensions: ["txt"], cached: cachedByFilename
            ).notes.count
        }
        report("filesystem-single-file-scan", targetedScan)

        let loadNotes = makeNotes(count: 50_000, bodyByteCount: bodyByteCount)
        let loadDocuments = loadNotes.map(SearchDocument.init)
        let loadSearch = measure(iterations: 7, warmups: 1) {
            SearchService.search(
                SearchQuery("term-that-is-never-present"), in: loadDocuments, sort: .init()
            ).count
        }
        report("load-search-missing-50000", loadSearch)
    }

    private static func makeNotes(count: Int, bodyByteCount: Int) -> [Note] {
        let words = [
            "amber", "archive", "autumn", "bridge", "canvas", "cedar", "circle", "cobalt",
            "coffee", "comet", "copper", "delta", "ember", "field", "forest", "garden",
            "harbor", "indigo", "island", "juniper", "lantern", "maple", "meadow", "memory",
            "morning", "notebook", "ocean", "paper", "pebble", "quiet", "river", "silver",
            "signal", "stone", "summer", "timber", "trail", "valley", "violet", "window",
        ].map { Array($0.utf8) }
        return (0..<count).map { index in
            let marker = " marker\(index)"
            let prefixBytes = max(0, bodyByteCount - marker.utf8.count)
            var bytes = Array("ordinary ".utf8)
            bytes.reserveCapacity(prefixBytes)
            var state = UInt64(index + 1) &* 6364136223846793005 &+ 1442695040888963407
            while bytes.count < prefixBytes {
                state = state &* 2862933555777941757 &+ 3037000493
                let word = words[Int(state % UInt64(words.count))]
                let remaining = prefixBytes - bytes.count
                if word.count + 1 <= remaining {
                    bytes.append(contentsOf: word)
                    bytes.append(0x20)
                } else {
                    bytes.append(contentsOf: word.prefix(remaining))
                }
            }
            let prefix = String(decoding: bytes, as: UTF8.self)
            let number = String(format: "%05d", index)
            return Note(
                title: "Reference Note \(number)", body: prefix + marker,
                filename: "Reference Note \(number).txt"
            )
        }
    }

    private static func measure(
        iterations: Int, warmups: Int, operation: () throws -> Int
    ) rethrows -> BenchmarkResult {
        for _ in 0..<warmups { _ = try operation() }
        var samples: [Double] = []
        var checksum = 0
        samples.reserveCapacity(iterations)
        for _ in 0..<iterations {
            let start = ContinuousClock.now
            checksum &+= try operation()
            let duration = start.duration(to: .now)
            let components = duration.components
            samples.append(Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1e15)
        }
        samples.sort()
        return BenchmarkResult(
            medianMilliseconds: samples[samples.count / 2],
            minimumMilliseconds: samples[0],
            maximumMilliseconds: samples[samples.count - 1],
            checksum: checksum
        )
    }

    private static func report(_ name: String, _ result: BenchmarkResult) {
        print(String(
            format: "BENCH %@ median_ms=%.3f min_ms=%.3f max_ms=%.3f checksum=%d",
            name, result.medianMilliseconds, result.minimumMilliseconds,
            result.maximumMilliseconds, result.checksum
        ))
    }
}

private struct BenchmarkResult {
    let medianMilliseconds: Double
    let minimumMilliseconds: Double
    let maximumMilliseconds: Double
    let checksum: Int
}
