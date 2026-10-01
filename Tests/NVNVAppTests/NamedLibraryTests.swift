import Foundation
import NVNVCore
import Testing
@testable import nvnv

@MainActor
@Suite("Named library switching", .serialized)
struct NamedLibraryTests {
    @Test func concurrentOpenRequestsCannotMixLibraries() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        // The first request yields during preparation. The overlapping request
        // must not replace any of its resources or register another destination.
        async let first: Void = model.openLibrary(fixture.a, confirmedAuxiliaryCreation: true)
        async let second: Void = model.openLibrary(fixture.b, confirmedAuxiliaryCreation: true)
        _ = await (first, second)
        #expect(model.libraries.count == 1)
        #expect(!model.isSwitchingLibrary)
        let active = try #require(model.activeLibrary)
        #expect(model.libraryURL == active.url)
        #expect(model.notes.first?.body == (active.name == "A" ? "alpha" : "beta"))
        await model.forgetLibrary()
    }

    @Test func sameLibraryIsANoOpAndCreationTargetsOnlyTheActiveFolder() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        await model.openLibrary(fixture.a, confirmedAuxiliaryCreation: true)
        let a = try #require(model.activeLibrary)
        model.userEnteredSearchText("alpha")
        let sessionID = model.librarySessionID
        await model.switchLibrary(to: a)
        #expect(model.librarySessionID == sessionID)
        #expect(model.query == "alpha")
        #expect(model.libraries.count == 1)
        await model.openLibrary(fixture.b, confirmedAuxiliaryCreation: true)
        model.userEnteredSearchText("New note")
        await model.submitSearch()
        model.updateBody("only in B")
        await model.switchLibrary(to: a)
        #expect(!FileManager.default.fileExists(atPath: fixture.a.appendingPathComponent("New note.txt").path))
        #expect(try String(contentsOf: fixture.b.appendingPathComponent("New note.txt"), encoding: .utf8) == "only in B")
        await model.forgetLibrary()
    }

    @Test func removedNoteIsNotReselectedWhenReturningToLibrary() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        await model.openLibrary(fixture.a, confirmedAuxiliaryCreation: true)
        try await settle(model)
        model.select([try #require(model.notes.first?.id)])
        let a = try #require(model.activeLibrary)
        await model.openLibrary(fixture.b, confirmedAuxiliaryCreation: true)
        try FileManager.default.removeItem(at: fixture.a.appendingPathComponent("Same.txt"))
        await model.switchLibrary(to: a)
        try await settle(model)
        #expect(model.selection.isEmpty)
        #expect(model.selectedNote == nil)
        #expect(model.results.isEmpty)
        await model.forgetLibrary()
    }

    @Test func roundTripFlushesEditsRestoresContextAndIsolatesSettings() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        await model.openLibrary(fixture.a, confirmedAuxiliaryCreation: true)
        model.userEnteredSearchText("alpha")
        try await settle(model)
        let a = try #require(model.notes.first)
        model.select([a.id])
        model.updateBody("alpha edited")
        model.updateSelection(NSRange(location: 3, length: 4))
        model.editorFontSize = 14
        model.showExcerpts = false
        let entryA = try #require(model.activeLibrary)
        model.renameLibrary(entryA, to: "Personal")

        await model.openLibrary(fixture.b, confirmedAuxiliaryCreation: true)
        #expect(model.errorMessage == nil)
        #expect(model.query.isEmpty)
        #expect(model.selection.isEmpty)
        #expect(model.notes.map(\.body) == ["beta"])
        #expect(model.editorFontSize == 12)
        #expect(model.showExcerpts)
        #expect(try String(contentsOf: fixture.a.appendingPathComponent("Same.txt"), encoding: .utf8) == "alpha edited")
        // The previous writer lock must have been released.
        do {
            let releasedLock = try LibraryLock(auxiliaryDirectory: fixture.a.appendingPathComponent(".nvnv"))
            #expect(releasedLock.isWritable)
        }

        await model.switchLibrary(to: entryA)
        try await settle(model)
        #expect(!model.isReadOnly)
        #expect(model.activeLibrary?.name == "Personal")
        #expect(model.query == "alpha")
        #expect(model.searchText == "Same")
        #expect(model.selectionKind == .explicit)
        #expect(model.selectedNote?.body == "alpha edited")
        #expect(model.selectedNote?.clampedSelection == NSRange(location: 3, length: 4))
        #expect(model.editorFontSize == 14)
        #expect(!model.showExcerpts)
        #expect(model.libraries.count == 2)
        await model.forgetLibrary()
    }

    @Test func unavailableDestinationLeavesCurrentLibraryAndSettingsIntact() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        await model.openLibrary(fixture.a, confirmedAuxiliaryCreation: true)
        model.editorFontSize = 13
        model.userEnteredSearchText("alpha")
        try await settle(model)
        let id = try #require(model.notes.first?.id)
        model.select([id])
        let before = model.libraryCatalog
        let sessionID = model.librarySessionID

        await model.openLibrary(fixture.root.appendingPathComponent("missing"), confirmedAuxiliaryCreation: true)
        #expect(model.errorMessage != nil)
        #expect(model.libraryCatalog == before)
        #expect(model.librarySessionID == sessionID)
        #expect(model.libraryURL == fixture.a)
        #expect(model.editorFontSize == 13)
        #expect(model.query == "alpha")
        #expect(model.selection == [id])
        #expect(!model.isSwitchingLibrary)
        model.updateBody("alpha still editable")
        try await model.flushAll()
        #expect(try String(contentsOf: fixture.a.appendingPathComponent("Same.txt"), encoding: .utf8) == "alpha still editable")
        await model.forgetLibrary()
    }

    @Test func failureAfterLoadingDestinationSettingsDoesNotApplyThem() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        await model.openLibrary(fixture.a, confirmedAuxiliaryCreation: true)
        model.editorFontSize = 13
        let auxiliary = fixture.b.appendingPathComponent(".nvnv")
        try FileManager.default.createDirectory(at: auxiliary, withIntermediateDirectories: true)
        // A file where the recovery directory should be forces preparation to fail.
        try Data("not a directory".utf8).write(to: auxiliary.appendingPathComponent("journal"))
        await model.openLibrary(fixture.b, confirmedAuxiliaryCreation: true)
        #expect(model.errorMessage != nil)
        #expect(model.libraryURL == fixture.a)
        #expect(model.editorFontSize == 13)
        #expect(model.libraries.count == 1)
        await model.forgetLibrary()
    }

    @Test func conflictBlocksSwitchAndRemoval() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        await model.openLibrary(fixture.a, confirmedAuxiliaryCreation: true)
        let note = try #require(model.notes.first)
        model.conflict = Conflict(noteID: note.id, baseBody: "alpha", appBody: "draft", fileBody: "external", fileHash: "hash")
        await model.openLibrary(fixture.b, confirmedAuxiliaryCreation: true)
        #expect(model.libraryURL == fixture.a)
        #expect(model.libraries.count == 1)
        #expect(model.conflict != nil)
        await model.forgetLibrary()
        #expect(model.libraryURL == fixture.a)
        #expect(model.libraries.count == 1)
        model.conflict = nil
        await model.forgetLibrary()
    }

    @Test func contextSurvivesCacheReplacementAndClampsCursor() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        await model.openLibrary(fixture.a, confirmedAuxiliaryCreation: true)
        try await settle(model)
        let original = try #require(model.notes.first)
        model.select([original.id])
        model.updateSelection(NSRange(location: 4, length: 1))
        let entry = try #require(model.activeLibrary)
        await model.openLibrary(fixture.b, confirmedAuxiliaryCreation: true)
        // Move only this fixture's disposable cache out of the way.
        let cache = fixture.a.appendingPathComponent(".nvnv/index.sqlite3")
        try FileManager.default.moveItem(at: cache, to: cache.appendingPathExtension("old"))
        try Data("hi".utf8).write(to: fixture.a.appendingPathComponent("Same.txt"))
        await model.switchLibrary(to: entry)
        try await settle(model)
        #expect(model.selectedNote?.id != original.id)
        #expect(model.selectedNote?.filename == "Same.txt")
        #expect(model.selectedNote?.clampedSelection == NSRange(location: 2, length: 0))
        await model.forgetLibrary()
    }

    @Test func deliberateDeselectionSurvivesSwitchButFreshLaunchStartsEmpty() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        await model.openLibrary(fixture.a, confirmedAuxiliaryCreation: true)
        model.userEnteredSearchText("Same")
        try await settle(model)
        model.returnToSearch()
        let entry = try #require(model.activeLibrary)
        await model.openLibrary(fixture.b, confirmedAuxiliaryCreation: true)
        await model.switchLibrary(to: entry)
        try await settle(model)
        #expect(model.query == "Same")
        #expect(model.selection.isEmpty)

        let reopened = AppModel(userDefaults: fixture.defaults)
        await reopened.restoreLastLibrary()
        try await settle(reopened)
        #expect(reopened.query.isEmpty)
        #expect(reopened.selection.isEmpty)
        #expect(reopened.libraries.count == 2)
        #expect(reopened.isReadOnly)
        await reopened.forgetLibrary()
        await model.forgetLibrary()
    }

    @Test func removalPreservesFilesAndOtherRegistrations() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        await model.openLibrary(fixture.a, confirmedAuxiliaryCreation: true)
        let a = try #require(model.activeLibrary)
        await model.openLibrary(fixture.b, confirmedAuxiliaryCreation: true)
        let b = try #require(model.activeLibrary)
        await model.removeLibrary(a)
        #expect(model.activeLibrary?.id == b.id)
        #expect(model.notes.map(\.body) == ["beta"])
        await model.openLibrary(fixture.a, confirmedAuxiliaryCreation: true)
        await model.forgetLibrary()
        #expect(model.libraryURL == nil)
        #expect(model.libraries.map(\.id) == [b.id])
        #expect(model.libraryCatalog.activeID == nil)
        #expect(fixture.defaults.string(forKey: "lastLibraryPath") == nil)
        for folder in [fixture.a, fixture.b] {
            #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Same.txt").path))
            #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(".nvnv/settings.json").path))
        }
        let reopened = AppModel(userDefaults: fixture.defaults)
        #expect(!reopened.isRestoringLibrary)
        #expect(reopened.libraries.map(\.id) == [b.id])
    }

    @Test func readOnlySessionDoesNotOverwriteLibrarySettings() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let writer = fixture.model
        await writer.openLibrary(fixture.a, confirmedAuxiliaryCreation: true)
        writer.editorFontSize = 14
        try await writer.flushAll()
        let settingsURL = fixture.a.appendingPathComponent(".nvnv/settings.json")
        let before = try Data(contentsOf: settingsURL)
        let reader = AppModel(userDefaults: fixture.defaults)
        await reader.restoreLastLibrary()
        #expect(reader.isReadOnly)
        reader.editorFontSize = 10
        await reader.openLibrary(fixture.b, confirmedAuxiliaryCreation: true)
        #expect(try Data(contentsOf: settingsURL) == before)
        await reader.forgetLibrary()
        await writer.forgetLibrary()
    }

    @Test func migrationAndMissingStartupLibraryKeepRegistrationsAccessible() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set(fixture.a.path, forKey: "lastLibraryPath")
        let model = AppModel(userDefaults: fixture.defaults)
        #expect(model.libraries.count == 1)
        await model.restoreLastLibrary()
        #expect(model.activeLibrary?.name == "A")
        let entry = try #require(model.activeLibrary)
        model.renameLibrary(entry, to: "Work")
        await model.openLibrary(fixture.b, confirmedAuxiliaryCreation: true)
        await model.forgetLibrary()
        fixture.defaults.set(try JSONEncoder().encode({ () -> LibraryCatalog in
            var catalog = model.libraryCatalog
            catalog.activate(fixture.a)
            return catalog
        }()), forKey: "namedLibraries")
        try FileManager.default.moveItem(at: fixture.a, to: fixture.root.appendingPathComponent("moved"))
        let missing = AppModel(userDefaults: fixture.defaults)
        await missing.restoreLastLibrary()
        #expect(!missing.isRestoringLibrary)
        #expect(missing.libraryURL == nil)
        #expect(missing.errorMessage != nil)
        #expect(missing.libraries.first?.name == "Work")
    }

    private func settle(_ model: AppModel) async throws {
        // Search executes off the main actor; allow both search and startup scan
        // to publish before asserting visible selection.
        try await Task.sleep(for: .milliseconds(180))
        try await model.flushAll()
    }

    @MainActor
    private struct Fixture {
        let root: URL
        let a: URL
        let b: URL
        let suite: String
        let defaults: UserDefaults
        let model: AppModel

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("nvnv-libraries-\(UUID().uuidString)").resolvingSymlinksInPath()
            a = root.appendingPathComponent("A", isDirectory: true)
            b = root.appendingPathComponent("B", isDirectory: true)
            for (folder, body) in [(a, "alpha"), (b, "beta")] {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try Data(body.utf8).write(to: folder.appendingPathComponent("Same.txt"))
            }
            suite = "nvnv-libraries-tests-\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: suite)!
            model = AppModel(userDefaults: defaults)
        }

        func cleanUp() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }
}
