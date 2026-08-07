import AppKit
import NVNVCore
import Testing
@testable import nvnv

@MainActor
@Suite("Plain-text editor indentation")
struct PlainTextEditorIndentationTests {
    @Test func tabAtCaretInsertsOnlyAtCaretAndKeepsSelectionCollapsed() {
        let original = "    * one\n    * two\n    * three"
        let editor = makeEditor(text: original)
        let coordinator = makeCoordinator(body: original, softTabs: true, tabWidth: 4)
        editor.setSelectedRange(NSRange(location: 10, length: 0))

        let handled = coordinator.textView(
            editor, doCommandBy: #selector(NSResponder.insertTab(_:))
        )

        #expect(handled)
        #expect(editor.string == "    * one\n        * two\n    * three")
        #expect(editor.selectedRange() == NSRange(location: 14, length: 0))

        editor.undo(nil)
        #expect(editor.string == original)
        #expect(editor.selectedRange() == NSRange(location: 10, length: 0))

        editor.redo(nil)
        #expect(editor.string == "    * one\n        * two\n    * three")
        #expect(editor.selectedRange() == NSRange(location: 14, length: 0))
    }

    @Test func tabWithSelectionIndentsLineWithoutReplacingSelection() {
        let original = "one\ntwo\nthree"
        let editor = makeEditor(text: original)
        let coordinator = makeCoordinator(body: original, softTabs: true, tabWidth: 2)
        editor.setSelectedRange(NSRange(location: 5, length: 1))

        let handled = coordinator.textView(
            editor, doCommandBy: #selector(NSResponder.insertTab(_:))
        )

        #expect(handled)
        #expect(editor.string == "one\n  two\nthree")
        #expect(editor.selectedRange() == NSRange(location: 7, length: 1))
    }

    @Test func backtabOutdentsOnlyCaretLineAndKeepsSelectionCollapsed() {
        let original = "one\n    two\n    three"
        let editor = makeEditor(text: original)
        let coordinator = makeCoordinator(body: original, softTabs: true, tabWidth: 4)
        editor.setSelectedRange(NSRange(location: 8, length: 0))

        let handled = coordinator.textView(
            editor, doCommandBy: #selector(NSResponder.insertBacktab(_:))
        )

        #expect(handled)
        #expect(editor.string == "one\ntwo\n    three")
        #expect(editor.selectedRange() == NSRange(location: 4, length: 0))
    }

    @Test func disabledTabIndentationDoesNotModifyText() {
        let original = "one\ntwo"
        let editor = makeEditor(text: original)
        let coordinator = makeCoordinator(
            body: original, softTabs: true, tabWidth: 4, tabIndents: false
        )
        editor.setSelectedRange(NSRange(location: 4, length: 0))

        let handled = coordinator.textView(
            editor, doCommandBy: #selector(NSResponder.insertTab(_:))
        )

        #expect(handled)
        #expect(editor.string == original)
        #expect(editor.selectedRange() == NSRange(location: 4, length: 0))
    }

    private func makeEditor(text: String) -> SessionTextView {
        let editor = SessionTextView(frame: .zero)
        editor.isEditable = true
        editor.isRichText = false
        editor.allowsUndo = true
        editor.string = text
        editor.sessionUndoManager = UndoManager()
        return editor
    }

    private func makeCoordinator(
        body: String, softTabs: Bool, tabWidth: Int, tabIndents: Bool = true
    ) -> PlainTextEditor.Coordinator {
        let note = Note(title: "Indentation", body: body, filename: "Indentation.txt")
        let editor = PlainTextEditor(
            note: note,
            editable: true,
            matchRanges: [],
            fontName: "",
            fontSize: 13,
            softTabs: softTabs,
            tabWidth: tabWidth,
            tabIndents: tabIndents,
            focusRequest: nil,
            command: nil,
            commandGeneration: 0,
            undoInvalidationGeneration: 0,
            undoRegistry: EditorUndoRegistry(),
            onChange: { _ in },
            onSelectionChange: { _ in },
            onEditingEnded: {},
            onFocus: {},
            onFocusRequestHandled: { _ in }
        )
        return PlainTextEditor.Coordinator(parent: editor)
    }
}
