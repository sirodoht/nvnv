import Foundation
import Testing
@testable import NVNVCore

@Suite("Named library catalog")
struct LibraryCatalogTests {
    @Test func migratesLegacyPathAndRoundTripsNames() throws {
        var catalog = LibraryCatalog.load(data: nil, legacyPath: "/tmp/nvnv-legacy")
        let original = try #require(catalog.activeLibrary)
        catalog.rename(original.id, to: "  Personal  ")
        let loaded = LibraryCatalog.load(data: try JSONEncoder().encode(catalog), legacyPath: "/tmp/ignored")
        #expect(loaded.libraries.count == 1)
        #expect(loaded.activeLibrary?.id == original.id)
        #expect(loaded.activeLibrary?.name == "Personal")
        #expect(loaded.activeLibrary?.path == original.path)
    }

    @Test func deduplicatesCanonicalPathsAndPreservesCustomName() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("notes")
        let link = root.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
        var catalog = LibraryCatalog()
        let entry = catalog.activate(folder)
        catalog.rename(entry.id, to: "Work")
        #expect(catalog.activate(link).id == entry.id)
        #expect(catalog.activate(folder.appendingPathComponent(".")).id == entry.id)
        #expect(catalog.libraries.count == 1)
        #expect(catalog.activeLibrary?.name == "Work")
    }

    @Test func allowsDuplicateLabelsRejectsEmptyAndRemovesOnlyRequestedEntry() {
        var catalog = LibraryCatalog()
        let a = catalog.activate(URL(fileURLWithPath: "/tmp/a/notes"))
        let b = catalog.activate(URL(fileURLWithPath: "/tmp/b/notes"))
        catalog.rename(b.id, to: " \n ")
        #expect(catalog.libraries.map(\.name) == ["notes", "notes"])
        catalog.remove(a.id)
        #expect(catalog.activeID == b.id)
        #expect(catalog.libraries.map(\.id) == [b.id])
        catalog.remove(b.id)
        #expect(catalog.activeID == nil)
        #expect(catalog.libraries.isEmpty)
    }

    @Test func emptyCatalogDoesNotRemigrateLegacyPath() throws {
        let loaded = LibraryCatalog.load(data: try JSONEncoder().encode(LibraryCatalog()), legacyPath: "/tmp/old")
        #expect(loaded.libraries.isEmpty)
        #expect(loaded.activeID == nil)
        #expect(LibraryCatalog.load(data: Data("broken".utf8), legacyPath: "/tmp/old").libraries.count == 1)
    }
}
