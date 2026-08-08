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

    @Test func openingLockedLibraryReadOnlyDoesNotPresentAnError() async throws {
        let root = try makeLibrary(["A.txt": "alpha"])
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = makeModel()
        let reader = makeModel()

        await writer.openLibrary(root, confirmedAuxiliaryCreation: true)
        await reader.openLibrary(root, confirmedAuxiliaryCreation: true)

        #expect(!writer.isReadOnly)
        #expect(reader.isReadOnly)
        #expect(reader.errorMessage == nil)
        await reader.forgetLibrary()
        await writer.forgetLibrary()
    }

    @Test func explicitSelectionShowsItsTitleWithoutReplacingTheSearchQuery() async throws {
        let root = try makeLibrary(["A.txt": "alpha", "B.txt": "beta"])
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel()
        await model.openLibrary(root, confirmedAuxiliaryCreation: true)
        model.userEnteredSearchText("alpha")
        try await Task.sleep(for: .milliseconds(150))
        let note = try #require(model.notes.first { $0.filename == "A.txt" })

        model.select([note.id])

        #expect(model.searchText == "A")
        #expect(model.query == "alpha")
        #expect(model.isShowingSelectedNoteTitle)

        model.returnToSearch()

        #expect(model.searchText == "alpha")
        #expect(model.query == "alpha")
        #expect(!model.isShowingSelectedNoteTitle)
        await model.forgetLibrary()
    }

    @Test func returnToSearchRestoresTheQueryAndIssuesNvALTNavigationRequests() async throws {
        let root = try makeLibrary(["A.txt": "alpha", "B.txt": "beta"])
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel()
        await model.openLibrary(root, confirmedAuxiliaryCreation: true)
        model.userEnteredSearchText("alpha")
        try await Task.sleep(for: .milliseconds(150))
        let note = try #require(model.notes.first { $0.filename == "A.txt" })
        model.select([note.id])
        #expect(model.focusSelectedNoteEditor())
        model.startRename()

        model.returnToSearch()

        #expect(model.selection.isEmpty)
        #expect(model.selectionKind == .none)
        #expect(model.searchText == "alpha")
        #expect(model.query == "alpha")
        #expect(!model.isShowingSelectedNoteTitle)
        #expect(!model.isRenaming)
        #expect(model.renameRequest == nil)
        #expect(model.focusRequest?.destination == .search(.collapseSelectionToEnd))
        #expect(model.listScrollRequest?.target == .top)
        await model.forgetLibrary()
    }

    @Test func deliberateDeselectionSurvivesRefreshUntilTheQueryChanges() async throws {
        let root = try makeLibrary(["hard tech map.txt": "internet"])
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel()
        await model.openLibrary(root, confirmedAuxiliaryCreation: true)
        model.userEnteredSearchText("hard te")
        try await Task.sleep(for: .milliseconds(150))
        #expect(model.selectionKind == .automatic)

        await model.submitSearch()
        model.returnToSearch()
        model.sort = NoteSort(field: .title, ascending: true)
        try await Task.sleep(for: .milliseconds(150))

        #expect(model.selection.isEmpty)
        #expect(model.selectionKind == .none)

        model.userEnteredSearchText("hard t")
        try await Task.sleep(for: .milliseconds(150))

        #expect(model.selectionKind == .automatic)
        #expect(model.selectedNote?.title == "hard tech map")
        await model.forgetLibrary()
    }

    @Test func onlyTheCurrentFocusRequestCanBeConsumed() {
        let model = makeModel()
        model.focusSearch()
        let staleID = model.focusRequest!.id
        model.returnToSearch()
        let currentID = model.focusRequest!.id

        model.consumeFocusRequest(staleID)
        #expect(model.focusRequest?.id == currentID)

        model.consumeFocusRequest(currentID)
        #expect(model.focusRequest == nil)
    }

    @Test func submittingAnAutomaticMatchEntersNoteMode() async throws {
        let root = try makeLibrary(["hard tech map.txt": "internet"])
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel()
        await model.openLibrary(root, confirmedAuxiliaryCreation: true)
        model.userEnteredSearchText("hard te")
        try await Task.sleep(for: .milliseconds(150))

        #expect(model.selectionKind == .automatic)
        #expect(!model.selectedEditorMatchRanges.isEmpty)

        await model.submitSearch()

        #expect(model.selectionKind == .explicit)
        #expect(model.isShowingSelectedNoteTitle)
        #expect(model.searchText == "hard tech map")
        #expect(model.query == "hard te")
        #expect(model.selectedEditorMatchRanges.isEmpty)
        await model.forgetLibrary()
    }

    @Test func renameUsesAListRequestAndKeepsTheSearchQuery() async throws {
        let root = try makeLibrary(["A.txt": "alpha"])
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel()
        await model.openLibrary(root, confirmedAuxiliaryCreation: true)
        try await Task.sleep(for: .milliseconds(150))
        let note = try #require(model.notes.first)
        model.select([note.id])

        model.startRename()

        #expect(model.renameRequest?.noteID == note.id)
        #expect(model.isRenaming)
        #expect(model.searchText == "A")
        #expect(model.query.isEmpty)

        await model.commitRename(to: "Renamed")

        #expect(model.renameRequest == nil)
        #expect(!model.isRenaming)
        #expect(model.searchText == "Renamed")
        #expect(model.query.isEmpty)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Renamed.txt").path))
        await model.forgetLibrary()
    }

    @Test func libraryPathUsesInjectedPreferencesForSaveRestoreAndForget() async throws {
        let root = try makeLibrary(["A.txt": "alpha"])
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "nvnv-library-preferences-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let firstModel = AppModel(userDefaults: defaults)
        await firstModel.openLibrary(root, confirmedAuxiliaryCreation: true)
        #expect(defaults.string(forKey: "lastLibraryPath") == root.standardizedFileURL.resolvingSymlinksInPath().path)

        let restoredModel = AppModel(userDefaults: defaults)
        #expect(restoredModel.isRestoringLibrary)
        await restoredModel.restoreLastLibrary()
        #expect(restoredModel.libraryURL == root.standardizedFileURL.resolvingSymlinksInPath())

        await firstModel.forgetLibrary()
        #expect(defaults.string(forKey: "lastLibraryPath") == nil)
        await restoredModel.forgetLibrary()
    }

    @Test func newlyCreatedExactMatchRemainsVisibleAfterSearchRefresh() async throws {
        let root = try makeLibrary([:])
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel()
        await model.openLibrary(root, confirmedAuxiliaryCreation: true)
        let title = "hello new text 12345"
        model.userEnteredSearchText(title)
        try await Task.sleep(for: .milliseconds(150))
        #expect(model.results.isEmpty)

        await model.submitSearch()
        let created = try #require(model.notes.first { $0.title == title })
        #expect(model.results.contains { $0.id == created.id })

        try await Task.sleep(for: .seconds(1))
        #expect(model.results.contains { $0.id == created.id })
        #expect(model.selection == [created.id])
        await model.forgetLibrary()
    }

    @Test func partialCachedSearchCannotHideMatchingExplicitSelection() throws {
        let selected = Note(
            title: "hello new text 12345", body: "", createdAt: .now,
            modifiedAt: .now, filename: "hello new text 12345.txt",
            lastSavedHash: "hash"
        )
        let unrelated = Note(
            title: "unrelated", body: "", createdAt: .now,
            modifiedAt: .now, filename: "unrelated.txt", lastSavedHash: "hash"
        )
        let documents = [selected, unrelated].reduce(into: [UUID: SearchDocument]()) {
            $0[$1.id] = SearchDocument(note: $1)
        }

        let resolved = AppModel.resultsPreservingMatchingSelection(
            found: [], selection: [selected.id], documents: documents,
            query: SearchQuery(selected.title), sort: NoteSort(field: .modified, ascending: false)
        )

        #expect(resolved.map(\.id) == [selected.id])
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
        #expect(model.undoInvalidationGenerations[note.id, default: 0] == 0)
        await model.resolveConflictUseFile(expectedConflictID: replacement.id)
        #expect(model.notes.first?.body == "second file")
        #expect(model.undoInvalidationGenerations[note.id] == 1)
        await model.forgetLibrary()
    }

    @Test func completingAnOlderJournalRemovalKeepsNewerOwnership() {
        let removed = UUID()
        let newer = UUID()

        #expect(AppModel.journalID(afterRemoving: removed, current: newer) == newer)
        #expect(AppModel.journalID(afterRemoving: removed, current: removed) == nil)
    }

    @Test func undoInvalidationsClearEachGenerationExactlyOnce() {
        let registry = EditorUndoRegistry()
        let noteID = UUID()
        let target = NSObject()
        let manager = registry.manager(for: noteID)
        manager.registerUndo(withTarget: target) { _ in }
        #expect(manager.canUndo)

        registry.applyInvalidation(for: noteID, generation: 1)
        #expect(!manager.canUndo)

        manager.registerUndo(withTarget: target) { _ in }
        registry.applyInvalidation(for: noteID, generation: 1)
        #expect(manager.canUndo)
        registry.applyInvalidation(for: noteID, generation: 2)
        #expect(!manager.canUndo)
    }

    @Test func successfulStartupRecoveryIsPersistedInTheSearchCache() async throws {
        let root = try makeLibrary(["A.txt": "disk body"])
        defer { try? FileManager.default.removeItem(at: root) }
        let scanned = try #require(
            LibraryScanner().scan(directory: root, recognizedExtensions: ["txt"]).notes.first
        )
        let journal = try RecoveryJournal(
            directory: root.appendingPathComponent(".nvnv/journal", isDirectory: true)
        )
        try await journal.record(JournalEntry(
            noteID: scanned.id, kind: .edit, baseHash: scanned.lastSavedHash,
            filename: scanned.filename, intendedFilename: scanned.filename,
            body: "recovered marker", revision: 1
        ))

        let model = makeModel()
        await model.openLibrary(root, confirmedAuxiliaryCreation: true)
        try await waitForIndexing(model)

        #expect(model.notes.first?.body == "recovered marker")
        let recoveredID = try #require(model.notes.first?.id)
        #expect(model.query.isEmpty)
        #expect(model.selection.isEmpty)
        let cache = try SQLiteCache(
            url: root.appendingPathComponent(".nvnv/index.sqlite3"), readOnly: true
        )
        let snapshot = try cache.snapshot()
        #expect(snapshot.searchIndexIsValid)
        #expect(snapshot.notes.first?.body == "recovered marker")
        #expect(try cache.candidateIDs(forNormalizedTerms: ["recovered"]) == [recoveredID])
        await model.forgetLibrary()
    }

    @Test func startupRecoveryConflictKeepsDiskCacheAndSearchesAppBodyConservatively() async throws {
        let root = try makeLibrary(["A.txt": "authoritative disk"])
        defer { try? FileManager.default.removeItem(at: root) }
        let scanned = try #require(
            LibraryScanner().scan(directory: root, recognizedExtensions: ["txt"]).notes.first
        )
        let journal = try RecoveryJournal(
            directory: root.appendingPathComponent(".nvnv/journal", isDirectory: true)
        )
        try await journal.record(JournalEntry(
            noteID: scanned.id, kind: .edit, baseHash: "different-base",
            filename: scanned.filename, intendedFilename: scanned.filename,
            body: "draft-only marker", revision: scanned.revision
        ))

        let model = makeModel()
        await model.openLibrary(root, confirmedAuxiliaryCreation: true)
        try await waitForIndexing(model)
        let conflictedID = try #require(model.notes.first?.id)
        #expect(model.conflict?.noteID == conflictedID)
        #expect(model.notes.first?.body == "draft-only marker")

        let cache = try SQLiteCache(
            url: root.appendingPathComponent(".nvnv/index.sqlite3"), readOnly: true
        )
        let snapshot = try cache.snapshot()
        #expect(snapshot.searchIndexIsValid)
        #expect(snapshot.notes.first?.body == "authoritative disk")

        model.userEnteredSearchText("draft-only")
        try await Task.sleep(for: .milliseconds(200))
        #expect(model.results.map(\.id) == [conflictedID])

        await model.resolveConflictUseFile()
        await model.forgetLibrary()
    }

    @Test func startupWatcherBufferTurnsPreActivationEventsIntoAFullRescan() {
        let buffer = DirectoryWatcherStartupBuffer()
        let recorder = ChangeRecorder()
        let path = URL(fileURLWithPath: "/tmp/A.txt")
        buffer.receive(.init(paths: [path], requiresFullRescan: false))

        buffer.activate { recorder.append($0) }
        buffer.receive(.init(paths: [path], requiresFullRescan: false))

        let changes = recorder.values
        #expect(changes.count == 2)
        #expect(changes[0].requiresFullRescan)
        #expect(changes[0].paths.isEmpty)
        #expect(!changes[1].requiresFullRescan)
        #expect(changes[1].paths == [path])
    }

    private func waitForIndexing(_ model: AppModel) async throws {
        for _ in 0..<500 {
            if !model.isIndexing { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("search cache rebuild did not finish")
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

private final class ChangeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [DirectoryWatcher.Change] = []

    var values: [DirectoryWatcher.Change] {
        lock.withLock { storage }
    }

    func append(_ change: DirectoryWatcher.Change) {
        lock.withLock { storage.append(change) }
    }
}
