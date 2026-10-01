import AppKit
import NVNVCore
import SwiftUI
import Testing
@testable import nvnv

@MainActor
@Suite("Plain-text editor focus")
struct PlainTextEditorFocusTests {
    @Test(arguments: [false, true])
    func gainingFocusShowsTheFullTitleBeforeAnyTextEdit(readOnly: Bool) throws {
        let defaults = try #require(UserDefaults(suiteName: "nvnv-editor-focus-tests-\(UUID())"))
        let model = AppModel(userDefaults: defaults)
        let note = Note(
            title: "doctor who wild blue yonder numbers", body: "10: fenslaw\n9: coliss",
            filename: "doctor who wild blue yonder numbers.txt"
        )
        model.userEnteredSearchText("doctor who")
        model.notes = [note]
        model.results = [SearchResult(note: note, titleRanges: [], bodyRanges: [])]
        model.select([note.id], explicitly: false)
        model.isReadOnly = readOnly

        // Exercise the native focus transition in an unshown window, without
        // activating the app or sending input to the user's windows.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: EditorPane(
            model: model, undoRegistry: EditorUndoRegistry(), findSession: EditorFindSession()
        ))
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let text = try #require(findEditor(in: host))
        try #require(window.makeFirstResponder(window))
        let cursor = NSRange(location: 4, length: 0)
        text.setSelectedRange(cursor)

        #expect(model.selectionKind == .automatic)
        #expect(model.searchText == "doctor who")
        try #require(window.makeFirstResponder(text))

        #expect(window.firstResponder === text)
        #expect(model.selectionKind == .explicit)
        #expect(model.isShowingSelectedNoteTitle)
        #expect(model.searchText == note.title)
        #expect(model.query == "doctor who")
        #expect(text.string == note.body)
        #expect(model.selectedNote?.body == note.body)
        #expect(text.selectedRange() == cursor)
        #expect(model.focusRequest == nil)

        // Each new focus transition must work, even without an intervening edit.
        try #require(window.makeFirstResponder(window))
        model.userEnteredSearchText("doctor who")
        model.select([note.id], explicitly: false)
        #expect(model.searchText == "doctor who")
        try #require(window.makeFirstResponder(text))
        #expect(model.selectionKind == .explicit)
        #expect(model.searchText == note.title)
        #expect(text.selectedRange() == cursor)
    }

    private func findEditor(in view: NSView) -> SessionTextView? {
        if let text = view as? SessionTextView { return text }
        for subview in view.subviews {
            if let text = findEditor(in: subview) { return text }
        }
        return nil
    }
}
