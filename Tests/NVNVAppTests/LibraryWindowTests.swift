import AppKit
import Foundation
import NVNVCore
import Testing
@testable import nvnv

@MainActor
@Suite("Independent library windows", .serialized)
struct LibraryWindowTests {
    @Test func windowsHaveIndependentNotesSearchAndSharedRegistrations() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let coordinator = fixture.coordinator
        let a = coordinator.makeModel()
        await coordinator.open(fixture.a, from: a, inNewWindow: false)
        let entryA = try #require(a.activeLibrary)
        a.userEnteredSearchText("alpha")
        await coordinator.open(fixture.b, from: a, inNewWindow: true)
        let b = try #require(coordinator.models.first { $0.libraryURL == fixture.b })
        #expect(a.libraryURL == fixture.a)
        #expect(a.query == "alpha")
        #expect(b.query.isEmpty)
        #expect(a.notes.map(\.body) == ["alpha"])
        #expect(b.notes.map(\.body) == ["beta"])
        #expect(!a.isReadOnly && !b.isReadOnly)
        a.renameLibrary(entryA, to: "Personal")
        #expect(b.libraries.first { $0.id == entryA.id }?.name == "Personal")
        a.conflict = Conflict(noteID: try #require(a.notes.first?.id), baseBody: "alpha",
                              appBody: "draft", fileBody: "external", fileHash: "hash")
        // An unrelated library opens even while A has an unresolved conflict.
        await coordinator.open(fixture.c, from: a, inNewWindow: true)
        #expect(coordinator.models.count == 3)
        #expect(a.conflict != nil)
        a.conflict = nil
        try await fixture.closeAll()
    }

    @Test func existingAndConcurrentCanonicalOpensReuseOneSession() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let coordinator = fixture.coordinator
        let a = coordinator.makeModel()
        await coordinator.open(fixture.a, from: a, inNewWindow: false)
        async let first: Void = coordinator.open(fixture.b, from: a, inNewWindow: true)
        async let second: Void = coordinator.open(fixture.b, from: a, inNewWindow: true)
        _ = await (first, second)
        let b = try #require(coordinator.models.first { $0.libraryURL == fixture.b })
        let link = fixture.root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.b)
        await coordinator.open(link, from: a, inNewWindow: false)
        #expect(coordinator.models.count == 2)
        #expect(a.libraryURL == fixture.a)
        #expect(b.libraryURL == fixture.b)
        #expect(!b.isReadOnly)
        #expect(coordinator.openLibraryIDs.count == 2)
        try await fixture.closeAll()
    }

    @Test func reopeningOutgoingLibraryDuringSwitchKeepsBothWindowsInWorkspace() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let coordinator = fixture.coordinator
        let source = coordinator.makeModel()
        await coordinator.open(fixture.a, from: source, inNewWindow: false)
        async let switching: Void = coordinator.open(fixture.c, from: source, inNewWindow: false)
        while source.libraryURL == fixture.a { await Task.yield() }
        await coordinator.open(fixture.a, from: source, inNewWindow: true)
        await switching
        #expect(coordinator.models.count == 2)
        #expect(Set(coordinator.openLibraryIDs) == Set(coordinator.models.compactMap { $0.activeLibrary?.id }))
        #expect(coordinator.models.allSatisfy { !$0.isReadOnly })
        try await fixture.closeAll()
    }

    @Test func layoutIsSavedPerLibraryAndRestoredAfterSwitching() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let coordinator = fixture.coordinator
        let a = coordinator.makeModel()
        await coordinator.open(fixture.a, from: a, inNewWindow: false)
        a.titleColumnWidth = 340
        a.modifiedColumnWidth = 170
        a.dividerFraction = 0.42
        a.windowFrame = LibraryWindowFrame(x: 30, y: 50, width: 600, height: 900)
        let frameA = a.windowFrame
        let entryA = try #require(a.activeLibrary)
        await coordinator.open(fixture.b, from: a, inNewWindow: true)
        let b = try #require(coordinator.models.first { $0.libraryURL == fixture.b })
        #expect(b.titleColumnWidth == 0)
        #expect(b.modifiedColumnWidth == 150)
        #expect(b.dividerFraction == 0.36)
        #expect(b.windowFrame == nil)
        b.titleColumnWidth = 280
        b.windowFrame = LibraryWindowFrame(x: 70, y: 80, width: 480, height: 800)
        await coordinator.open(fixture.c, from: a, inNewWindow: false)
        await a.switchLibrary(to: entryA)
        #expect(a.titleColumnWidth == 340)
        #expect(a.modifiedColumnWidth == 170)
        #expect(a.dividerFraction == 0.42)
        #expect(a.windowFrame == frameA)
        #expect(b.titleColumnWidth == 280)
        try await fixture.closeAll()
    }

    @Test func cleanQuitFlushesBothLibrariesAndRelaunchRestoresEveryWindow() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let coordinator = fixture.coordinator
        let a = coordinator.makeModel()
        await coordinator.open(fixture.a, from: a, inNewWindow: false)
        await coordinator.open(fixture.b, from: a, inNewWindow: true)
        let b = try #require(coordinator.models.first { $0.libraryURL == fixture.b })
        try await Task.sleep(for: .milliseconds(180))
        a.select([try #require(a.notes.first?.id)])
        b.select([try #require(b.notes.first?.id)])
        a.updateBody("alpha saved")
        b.updateBody("beta saved")
        a.userEnteredSearchText("alpha")
        b.userEnteredSearchText("beta")
        a.windowIsFullScreen = true
        try await coordinator.prepareForQuit()
        #expect(try String(contentsOf: fixture.a.appendingPathComponent("Note.txt"), encoding: .utf8) == "alpha saved")
        #expect(try String(contentsOf: fixture.b.appendingPathComponent("Note.txt"), encoding: .utf8) == "beta saved")
        let openIDs = Set(coordinator.openLibraryIDs)
        for model in coordinator.models { coordinator.didClose(model) }
        let relaunched = LibraryWindowCoordinator(userDefaults: fixture.defaults)
        let initial = relaunched.makeModel()
        await relaunched.restoreWorkspace(into: initial)
        #expect(relaunched.models.count == 2)
        #expect(Set(relaunched.openLibraryIDs) == openIDs)
        #expect(relaunched.models.allSatisfy { $0.query.isEmpty && $0.selection.isEmpty && !$0.isReadOnly })
        #expect(relaunched.models.first { $0.libraryURL == fixture.a }?.windowIsFullScreen == true)
        try await relaunched.prepareForQuit()
        for model in relaunched.models { relaunched.didClose(model) }
    }

    @Test func failedQuitStillSavesOtherLibrariesAndUnfreezesEveryWindow() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let coordinator = fixture.coordinator
        let a = coordinator.makeModel()
        await coordinator.open(fixture.a, from: a, inNewWindow: false)
        await coordinator.open(fixture.b, from: a, inNewWindow: true)
        let b = try #require(coordinator.models.first { $0.libraryURL == fixture.b })
        try await Task.sleep(for: .milliseconds(180))
        b.select([try #require(b.notes.first?.id)])
        b.updateBody("beta survives")
        a.conflict = Conflict(noteID: try #require(a.notes.first?.id), baseBody: "alpha",
                              appBody: "draft", fileBody: "external", fileHash: "hash")
        do {
            try await coordinator.prepareForQuit()
            Issue.record("Quit should fail while A has a conflict")
        } catch {
            #expect(error.localizedDescription.contains("A"))
        }
        #expect(!coordinator.isQuitting)
        #expect(coordinator.models.allSatisfy { !$0.isSwitchingLibrary })
        #expect(try String(contentsOf: fixture.b.appendingPathComponent("Note.txt"), encoding: .utf8) == "beta survives")
        a.conflict = nil
        try await fixture.closeAll()
    }

    @Test func closingKeepsRegistrationButRemovesOnlyThatWindowFromRestoration() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let coordinator = fixture.coordinator
        let a = coordinator.makeModel()
        await coordinator.open(fixture.a, from: a, inNewWindow: false)
        let entryA = try #require(a.activeLibrary)
        await coordinator.open(fixture.b, from: a, inNewWindow: true)
        let b = try #require(coordinator.models.first { $0.libraryURL == fixture.b })
        let entryB = try #require(b.activeLibrary)
        try await a.prepareForWindowClose()
        coordinator.didClose(a)
        #expect(coordinator.models.count == 1)
        #expect(coordinator.openLibraryIDs == [entryB.id])
        #expect(coordinator.catalogStore.catalog.libraries.contains { $0.id == entryA.id })
        let lock = try LibraryLock(auxiliaryDirectory: fixture.a.appendingPathComponent(".nvnv"))
        #expect(lock.isWritable)
        let reload = LibraryWindowCoordinator(userDefaults: fixture.defaults)
        #expect(reload.openLibraryIDs == [entryB.id])
        try await fixture.closeAll()
    }

    @Test func reopeningClosedLibraryRestoresContextInANewModel() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let coordinator = fixture.coordinator
        let original = coordinator.makeModel()
        await coordinator.open(fixture.a, from: original, inNewWindow: false)
        original.userEnteredSearchText("alpha")
        try await Task.sleep(for: .milliseconds(180))
        original.select([try #require(original.notes.first?.id)])
        original.updateSelection(NSRange(location: 2, length: 1))
        await coordinator.open(fixture.b, from: original, inNewWindow: true)
        let b = try #require(coordinator.models.first { $0.libraryURL == fixture.b })
        try await original.prepareForWindowClose()
        coordinator.didClose(original)
        await coordinator.open(fixture.a, from: b, inNewWindow: true)
        let reopened = try #require(coordinator.models.first { $0.libraryURL == fixture.a })
        try await Task.sleep(for: .milliseconds(180))
        #expect(reopened !== original)
        #expect(reopened.query == "alpha")
        #expect(reopened.selectionKind == .explicit)
        #expect(reopened.selectedNote?.clampedSelection == NSRange(location: 2, length: 1))
        #expect(b.query.isEmpty)
        try await fixture.closeAll()
    }

    @Test func removingLibraryFromAnotherWindowSafelyUnloadsItsOwner() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let coordinator = fixture.coordinator
        let a = coordinator.makeModel()
        await coordinator.open(fixture.a, from: a, inNewWindow: false)
        let entryA = try #require(a.activeLibrary)
        await coordinator.open(fixture.b, from: a, inNewWindow: true)
        let b = try #require(coordinator.models.first { $0.libraryURL == fixture.b })
        await b.removeLibrary(entryA)
        #expect(a.libraryURL == nil)
        #expect(b.libraryURL == fixture.b)
        #expect(b.libraries.count == 1)
        #expect(coordinator.openLibraryIDs == [b.activeLibrary?.id].compactMap { $0 })
        #expect(FileManager.default.fileExists(atPath: fixture.a.appendingPathComponent("Note.txt").path))
        try await fixture.closeAll()
    }

    @Test func unavailableRestoredFolderKeepsOtherWindowsAndItsRegistration() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let coordinator = fixture.coordinator
        let a = coordinator.makeModel()
        await coordinator.open(fixture.a, from: a, inNewWindow: false)
        await coordinator.open(fixture.b, from: a, inNewWindow: true)
        try await fixture.closeAll()
        try FileManager.default.moveItem(at: fixture.a, to: fixture.root.appendingPathComponent("moved"))
        let reload = LibraryWindowCoordinator(userDefaults: fixture.defaults)
        let welcome = reload.makeModel()
        await reload.restoreWorkspace(into: welcome)
        #expect(reload.models.contains { $0.libraryURL == fixture.b })
        #expect(welcome.errorMessage != nil)
        #expect(welcome.libraries.count == 2)
        #expect(reload.openLibraryIDs.count == 2)
        try await reload.prepareForQuit()
        for model in reload.models { reload.didClose(model) }
    }

    @Test func settingsStayPinnedWhenAnotherLibraryGetsFocusOrSourceSwitches() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let coordinator = fixture.coordinator
        let a = coordinator.makeModel()
        await coordinator.open(fixture.a, from: a, inNewWindow: false)
        coordinator.settingsLibraryID = a.activeLibrary?.id
        await coordinator.open(fixture.b, from: a, inNewWindow: true)
        let b = try #require(coordinator.models.first { $0.libraryURL == fixture.b })
        coordinator.focused(b)
        #expect(coordinator.settingsModel === a)
        await coordinator.open(fixture.c, from: a, inNewWindow: false)
        #expect(coordinator.settingsModel == nil)
        try await fixture.closeAll()
    }

    @MainActor
    private struct Fixture {
        let root: URL
        let a: URL
        let b: URL
        let c: URL
        let suite: String
        let defaults: UserDefaults
        let coordinator: LibraryWindowCoordinator

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("nvnv-windows-\(UUID())").resolvingSymlinksInPath()
            a = root.appendingPathComponent("A", isDirectory: true)
            b = root.appendingPathComponent("B", isDirectory: true)
            c = root.appendingPathComponent("C", isDirectory: true)
            for (folder, body) in [(a, "alpha"), (b, "beta"), (c, "gamma")] {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try Data(body.utf8).write(to: folder.appendingPathComponent("Note.txt"))
            }
            suite = "nvnv-window-tests-\(UUID())"
            defaults = UserDefaults(suiteName: suite)!
            coordinator = LibraryWindowCoordinator(userDefaults: defaults)
        }

        func closeAll() async throws {
            try await coordinator.prepareForQuit()
            for model in coordinator.models { coordinator.didClose(model) }
        }

        func cleanUp() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }
}
