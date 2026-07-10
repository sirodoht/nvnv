import Foundation
import NVNVCore

@main
struct NVNVProbes {
    static func main() async throws {
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
    }
}
