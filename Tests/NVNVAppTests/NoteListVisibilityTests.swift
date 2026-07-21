import AppKit
import SwiftUI
import Testing
@testable import nvnv

@MainActor
@Suite("Native note list visibility", .serialized)
struct NoteListVisibilityTests {
    @Test func createdExactMatchIsVisibleAfterADeepListCollapses() async throws {
        let root = try makeLibrary(noteCount: 80)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel()
        await model.openLibrary(root, confirmedAuxiliaryCreation: true)
        let initialNoteCount = model.notes.count

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 620),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
        )
        defer { window.close() }
        let hostingView = NSHostingView(rootView: ContentView(model: model))
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        window.layoutIfNeeded()
        try await settleUI()

        let table = try #require(firstSubview(of: NSTableView.self, in: hostingView))
        #expect(table.numberOfRows == initialNoteCount)
        let scrollView = try #require(table.enclosingScrollView)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: table.rect(ofRow: table.numberOfRows - 1).minY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        #expect(table.visibleRect.minY > 0)

        let title = "nvnv ui create visibility repro 12345"
        let searchField = try #require(firstSubview(of: NSTextField.self, in: hostingView) { $0.isEditable })
        #expect(window.makeFirstResponder(searchField))
        let fieldEditor = try #require(searchField.currentEditor() as? NSTextView)
        fieldEditor.selectAll(nil)
        fieldEditor.insertText(title, replacementRange: fieldEditor.selectedRange())
        try await settleUI()
        #expect(model.searchText == title)
        #expect(table.numberOfRows == 0)

        fieldEditor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        try await settleUI()

        let noteEditor = try #require(window.firstResponder as? NSTextView)
        #expect(noteEditor !== fieldEditor)
        noteEditor.insertText("askjdhkjh", replacementRange: noteEditor.selectedRange())
        try await Task.sleep(for: .seconds(1))
        try await settleUI()

        #expect(table.numberOfRows == 1)
        #expect(table.visibleRect.intersects(table.rect(ofRow: 0)))
        #expect(model.selection == Set([model.notes.first { $0.title == title }?.id].compactMap { $0 }))
        #expect(model.selectedNote?.body == "askjdhkjh")
        await model.forgetLibrary()
    }

    private func settleUI() async throws {
        for _ in 0..<4 {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    private func firstSubview<T: NSView>(
        of type: T.Type, in view: NSView, where predicate: (T) -> Bool = { _ in true }
    ) -> T? {
        if let match = view as? T, predicate(match) { return match }
        for subview in view.subviews {
            if let match = firstSubview(of: type, in: subview, where: predicate) { return match }
        }
        return nil
    }

    private func makeModel() -> AppModel {
        let suite = "nvnv-note-list-visibility-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return AppModel(userDefaults: defaults)
    }

    private func makeLibrary(noteCount: Int) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nvnv-note-list-visibility-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for index in 0..<noteCount {
            try "body \(index)".write(
                to: root.appendingPathComponent(String(format: "Note %03d.txt", index)),
                atomically: true, encoding: .utf8
            )
        }
        return root
    }
}
