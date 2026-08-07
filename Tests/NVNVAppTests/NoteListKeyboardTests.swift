import AppKit
import NVNVCore
import Testing
@testable import nvnv

@MainActor
@Suite("Note list keyboard behavior")
struct NoteListKeyboardTests {
    @Test(arguments: [UInt16(36), UInt16(76)])
    func enterFocusesTheSelectedNoteEditor(keyCode: UInt16) {
        let table = NoteListNativeTableView()
        var handledCount = 0
        table.onEnter = {
            handledCount += 1
            return true
        }

        table.keyDown(with: keyEvent(keyCode: keyCode))

        #expect(handledCount == 1)
    }

    @Test func modifiedEnterIsNotIntercepted() {
        let table = NoteListNativeTableView()
        var handledCount = 0
        table.onEnter = {
            handledCount += 1
            return true
        }

        table.keyDown(with: keyEvent(keyCode: 36, modifiers: .command))

        #expect(handledCount == 0)
    }

    @Test func modelFocusRequestPreservesTheSelectedNotesCursor() {
        let model = makeModel()
        let note = Note(
            title: "Cursor", body: "0123456789", cursorStart: 6, cursorLength: 0,
            filename: "Cursor.txt"
        )
        model.notes = [note]
        model.results = [SearchResult(note: note, titleRanges: [], bodyRanges: [])]
        model.select([note.id])

        #expect(model.focusSelectedNoteEditor())
        #expect(model.editorFocusRequest?.noteID == note.id)
        #expect(model.selectedNote?.clampedSelection == NSRange(location: 6, length: 0))
    }

    @Test func modelDoesNotRequestEditorFocusWithoutOneSelectedNote() {
        let model = makeModel()

        #expect(!model.focusSelectedNoteEditor())
        #expect(model.editorFocusRequest == nil)
    }

    private func keyEvent(
        keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: keyCode == 76 ? "\u{3}" : "\r",
            charactersIgnoringModifiers: keyCode == 76 ? "\u{3}" : "\r",
            isARepeat: false,
            keyCode: keyCode
        )!
    }

    private func makeModel() -> AppModel {
        let suite = "nvnv-note-list-keyboard-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return AppModel(userDefaults: defaults)
    }
}
