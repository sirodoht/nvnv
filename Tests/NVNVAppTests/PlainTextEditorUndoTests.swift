import AppKit
import Testing
@testable import nvnv

@MainActor
@Suite("Plain-text editor undo routing")
struct PlainTextEditorUndoTests {
    @Test func responderActionsReachTheSessionUndoManager() {
        let textView = SessionTextView(frame: .zero)
        let manager = UndoManager()
        textView.allowsUndo = true
        textView.isEditable = true
        textView.sessionUndoManager = manager
        textView.insertText("abc", replacementRange: NSRange(location: 0, length: 0))

        let undoAction = #selector(SessionTextView.undo(_:))
        let undo = NSMenuItem(
            title: "Undo", action: #selector(SessionTextView.undo(_:)), keyEquivalent: "z"
        )
        #expect(manager.canUndo)
        #expect(textView.validateUserInterfaceItem(undo))
        #expect(textView.tryToPerform(undoAction, with: undo))
        #expect(textView.string.isEmpty)

        let redoAction = #selector(SessionTextView.redo(_:))
        let redo = NSMenuItem(
            title: "Redo", action: #selector(SessionTextView.redo(_:)), keyEquivalent: "Z"
        )
        #expect(manager.canRedo)
        #expect(textView.validateUserInterfaceItem(redo))
        #expect(textView.tryToPerform(redoAction, with: redo))
        #expect(textView.string == "abc")
    }

    @Test func undoAndRedoAreDisabledWhenTheEditorIsReadOnly() {
        let textView = SessionTextView(frame: .zero)
        let manager = UndoManager()
        textView.allowsUndo = true
        textView.isEditable = true
        textView.sessionUndoManager = manager
        textView.insertText("abc", replacementRange: NSRange(location: 0, length: 0))
        textView.isEditable = false

        let undo = NSMenuItem(
            title: "Undo", action: #selector(SessionTextView.undo(_:)), keyEquivalent: "z"
        )
        #expect(!textView.validateUserInterfaceItem(undo))
        textView.undo(undo)
        #expect(textView.string == "abc")
    }
}
