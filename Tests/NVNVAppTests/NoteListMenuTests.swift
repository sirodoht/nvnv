import AppKit
import NVNVCore
import SwiftUI
import Testing
@testable import nvnv

@MainActor
@Suite("Note list menus", .serialized)
struct NoteListMenuTests {
    @Test func rowMenuDisablesSingleNoteActionsForAMultipleSelection() async throws {
        let model = makeModel(titles: ["Alpha", "Beta"])
        model.select(Set(model.notes.map(\.id)))
        let (window, scrollView) = try await host(model)
        defer { window.close() }

        let menu = try #require(scrollView.noteTableView.contextMenuProvider?(0))
        // AppKit runs this validation pass before it shows a menu.
        menu.update()

        #expect(try item("Rename", in: menu).isEnabled == false)
        #expect(try item("Show in Finder", in: menu).isEnabled == false)
        #expect(try item("Move to Trash", in: menu).isEnabled)
    }

    @Test func rowMenuDisablesWritesInAReadOnlyLibrary() async throws {
        let model = makeModel(titles: ["Alpha"])
        model.select([model.notes[0].id])
        model.isReadOnly = true
        let (window, scrollView) = try await host(model)
        defer { window.close() }

        let menu = try #require(scrollView.noteTableView.contextMenuProvider?(0))
        menu.update()

        #expect(try item("Rename", in: menu).isEnabled == false)
        #expect(try item("Show in Finder", in: menu).isEnabled)
        #expect(try item("Move to Trash", in: menu).isEnabled == false)
    }

    @Test func columnMenuDisablesHidingTheLastVisibleColumn() async throws {
        let model = makeModel(titles: ["Alpha"])
        for column in NoteListColumn.allCases where column != .title {
            model.setNoteListColumn(column, visible: false)
        }
        #expect(model.visibleNoteListColumns == [.title])
        let (window, scrollView) = try await host(model)
        defer { window.close() }

        let menu = try #require(scrollView.noteHeaderView.menuProvider?())
        menu.update()

        for column in NoteListColumn.allCases {
            #expect(try item(column.title, in: menu).isEnabled == (column != .title))
        }
    }

    private func item(_ title: String, in menu: NSMenu) throws -> NSMenuItem {
        try #require(menu.items.first { $0.title == title })
    }

    private func host(_ model: AppModel) async throws -> (NSWindow, NoteListScrollView) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        let hostingView = NSHostingView(rootView: NoteListView(model: model))
        window.contentView = hostingView
        window.layoutIfNeeded()
        for _ in 0..<4 {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(25))
        }
        return (window, try #require(firstSubview(of: NoteListScrollView.self, in: hostingView)))
    }

    private func firstSubview<T: NSView>(of type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let match = firstSubview(of: type, in: subview) { return match }
        }
        return nil
    }

    private func makeModel(titles: [String]) -> AppModel {
        let suite = "nvnv-note-list-menu-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let model = AppModel(userDefaults: defaults)
        let notes = titles.map { Note(title: $0, body: "", filename: "\($0).txt") }
        model.notes = notes
        model.results = notes.map { SearchResult(note: $0, titleRanges: [], bodyRanges: []) }
        return model
    }
}
