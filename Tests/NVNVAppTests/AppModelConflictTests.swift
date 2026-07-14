import Foundation
import NVNVCore
import Testing
@testable import nvnv

@MainActor
@Suite("App model save and conflict coordination", .serialized)
struct AppModelConflictTests {
    @Test func clearingConflictDismissesItsSheet() {
        let model = makeModel()
        model.conflict = Conflict(
            noteID: UUID(), baseBody: "base", appBody: "app",
            fileBody: "file", fileHash: "hash"
        )
        #expect(model.isConflictPresented)

        model.conflict = nil

        #expect(!model.isConflictPresented)
    }

    @Test func unrelatedNoteRemainsEditableDuringConflict() async throws {
        let root = try makeLibrary(["A.txt": "alpha", "B.txt": "beta"])
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel()
        await model.openLibrary(root, confirmedAuxiliaryCreation: true)
        let a = try #require(model.notes.first { $0.filename == "A.txt" })
        let b = try #require(model.notes.first { $0.filename == "B.txt" })
        model.conflict = Conflict(
            noteID: a.id, baseBody: "alpha", appBody: "app alpha",
            fileBody: "file alpha", fileHash: a.lastSavedHash
        )
        model.selection = [b.id]

        model.updateBody("edited beta")

        #expect(model.notes.first { $0.id == b.id }?.body == "edited beta")
        model.conflict = nil
        try await model.flushAll()
        await model.forgetLibrary()
    }

    @Test func ownSaveWatcherEventDoesNotCreateConflict() async throws {
        let root = try makeLibrary(["A.txt": "alpha"])
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel()
        await model.openLibrary(root, confirmedAuxiliaryCreation: true)
        let note = try #require(model.notes.first)
        model.selection = [note.id]
        model.updateBody("edited alpha")

        try await model.flushAll()
        try await Task.sleep(for: .milliseconds(700))

        #expect(model.conflict == nil)
        #expect(try String(contentsOf: root.appendingPathComponent("A.txt"), encoding: .utf8) == "edited alpha")
        await model.forgetLibrary()
    }

    @Test func externalRenamePreservesDirtyBody() async throws {
        let root = try makeLibrary(["A.txt": "alpha"])
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel()
        await model.openLibrary(root, confirmedAuxiliaryCreation: true)
        let note = try #require(model.notes.first)
        model.selection = [note.id]
        model.updateBody("dirty alpha")
        try FileManager.default.moveItem(
            at: root.appendingPathComponent("A.txt"),
            to: root.appendingPathComponent("Renamed.txt")
        )

        try await Task.sleep(for: .milliseconds(600))
        try await model.flushAll()

        let renamed = try #require(model.notes.first { $0.id == note.id })
        #expect(renamed.filename == "Renamed.txt")
        #expect(renamed.body == "dirty alpha")
        #expect(model.notes.filter { $0.id == note.id }.count == 1)
        #expect(model.conflict == nil)
        await model.forgetLibrary()
    }

    @Test func simultaneousConflictsAreResolvedInDetectionOrder() async throws {
        let root = try makeLibrary(["A.txt": "alpha", "B.txt": "beta"])
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel()
        await model.openLibrary(root, confirmedAuxiliaryCreation: true)
        let a = try #require(model.notes.first { $0.filename == "A.txt" })
        let b = try #require(model.notes.first { $0.filename == "B.txt" })
        let first = Conflict(
            noteID: a.id, baseBody: a.body, appBody: "app alpha",
            fileBody: "file alpha", fileHash: a.lastSavedHash
        )
        let second = Conflict(
            noteID: b.id, baseBody: b.body, appBody: "app beta",
            fileBody: "file beta", fileHash: b.lastSavedHash
        )

        model.presentConflict(first)
        model.presentConflict(second)

        #expect(model.conflict?.id == first.id)
        await model.resolveConflictUseFile()
        #expect(model.conflict?.id == second.id)
        await model.resolveConflictUseFile()
        #expect(model.conflict == nil)
        await model.forgetLibrary()
    }

    @Test func staleResolverCannotResolveANewerConflictForTheSameNote() async throws {
        let root = try makeLibrary(["A.txt": "alpha"])
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel()
        await model.openLibrary(root, confirmedAuxiliaryCreation: true)
        let note = try #require(model.notes.first)
        let first = Conflict(
            noteID: note.id, baseBody: note.body, appBody: "first app",
            fileBody: "first file", fileHash: note.lastSavedHash
        )
        let replacement = Conflict(
            noteID: note.id, baseBody: note.body, appBody: "second app",
            fileBody: "second file", fileHash: note.lastSavedHash
        )
        model.presentConflict(first)
        model.presentConflict(replacement)

        await model.resolveConflictUseFile(expectedConflictID: first.id)

        #expect(model.conflict?.id == replacement.id)
        #expect(model.notes.first?.body == "alpha")
        await model.resolveConflictUseFile(expectedConflictID: replacement.id)
        #expect(model.notes.first?.body == "second file")
        await model.forgetLibrary()
    }

    private func makeModel() -> AppModel {
        let suite = "nvnv-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return AppModel(userDefaults: defaults)
    }

    private func makeLibrary(_ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nvnv-app-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (filename, body) in files {
            try Data(body.utf8).write(to: root.appendingPathComponent(filename))
        }
        return root
    }
}
