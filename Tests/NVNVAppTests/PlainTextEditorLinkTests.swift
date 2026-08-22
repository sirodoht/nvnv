import AppKit
import NVNVCore
import Testing
@testable import nvnv

@MainActor
@Suite("Plain-text editor link refresh")
struct PlainTextEditorLinkTests {
    private struct LinkSnapshot: Equatable {
        let text: String
        let url: String
        let range: NSRange
    }

    @Test func pasteDetectsHTTPLinks() throws {
        let editor = makeEditor(text: "Before ")
        editor.setSelectedRange(NSRange(location: 7, length: 0))
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("nvnv-link-test-\(UUID())"))
        pasteboard.clearContents()
        try #require(pasteboard.setString("https://example.com/path", forType: .string))

        try #require(editor.readSelection(from: pasteboard, type: .string))

        #expect(links(in: editor) == [
            LinkSnapshot(
                text: "https://example.com/path",
                url: "https://example.com/path",
                range: NSRange(location: 7, length: 24)
            )
        ])
    }

    @Test func editingInsideURLRefreshesItsLinkAttribute() {
        let editor = makeEditor(text: "Visit https://example.com now")

        editor.insertText(
            "not-a-link",
            replacementRange: NSRange(location: 6, length: 19)
        )
        #expect(links(in: editor).isEmpty)

        editor.insertText(
            "http://example.org",
            replacementRange: NSRange(location: 6, length: 10)
        )
        #expect(links(in: editor) == [
            LinkSnapshot(
                text: "http://example.org",
                url: "http://example.org",
                range: NSRange(location: 6, length: 18)
            )
        ])
    }

    @Test func undoAndRedoRefreshLinkAttributes() {
        let editor = makeEditor(text: "Before ")
        editor.setSelectedRange(NSRange(location: 7, length: 0))

        editor.insertText("https://example.com", replacementRange: editor.selectedRange())
        #expect(links(in: editor).count == 1)

        editor.undo(nil)
        #expect(editor.string == "Before ")
        #expect(links(in: editor).isEmpty)

        editor.redo(nil)
        #expect(editor.string == "Before https://example.com")
        #expect(links(in: editor).count == 1)
    }

    @Test func indentOutdentAndTheirUndoKeepLinksExactWhenNoteBeginsWithURL() {
        let original = "https://example.com\nplain text"
        let editor = makeEditor(text: original)
        let coordinator = makeCoordinator(body: original)
        editor.setSelectedRange(NSRange(location: 0, length: (original as NSString).length))

        coordinator.perform(.indent, in: editor)
        #expect(editor.string == "    https://example.com\n    plain text")
        #expect(links(in: editor) == [
            LinkSnapshot(
                text: "https://example.com",
                url: "https://example.com",
                range: NSRange(location: 4, length: 19)
            )
        ])

        editor.undo(nil)
        #expect(editor.string == original)
        #expect(links(in: editor).first?.range == NSRange(location: 0, length: 19))

        editor.redo(nil)
        #expect(editor.string == "    https://example.com\n    plain text")
        #expect(links(in: editor).first?.range == NSRange(location: 4, length: 19))

        coordinator.perform(.outdent, in: editor)
        #expect(editor.string == original)
        #expect(links(in: editor) == [
            LinkSnapshot(
                text: "https://example.com",
                url: "https://example.com",
                range: NSRange(location: 0, length: 19)
            )
        ])
    }

    private func makeEditor(text: String) -> SessionTextView {
        let editor = SessionTextView(frame: .zero)
        editor.isEditable = true
        editor.isRichText = false
        editor.allowsUndo = true
        editor.isAutomaticLinkDetectionEnabled = false
        editor.string = text
        editor.refreshDetectedLinks()
        editor.sessionUndoManager = UndoManager()
        return editor
    }

    private func makeCoordinator(body: String) -> PlainTextEditor.Coordinator {
        let note = Note(title: "Links", body: body, filename: "Links.txt")
        let editor = PlainTextEditor(
            note: note,
            editable: true,
            matchRanges: [],
            findSeedText: "",
            fontName: "",
            fontSize: 13,
            softTabs: true,
            tabWidth: 4,
            tabIndents: true,
            focusRequest: nil,
            command: nil,
            commandGeneration: 0,
            undoInvalidationGeneration: 0,
            undoRegistry: EditorUndoRegistry(),
            findSession: EditorFindSession(),
            onChange: { _ in },
            onSelectionChange: { _ in },
            onEditingEnded: {},
            onFocus: {},
            onFocusRequestHandled: { _ in }
        )
        return PlainTextEditor.Coordinator(parent: editor)
    }

    private func links(in editor: NSTextView) -> [LinkSnapshot] {
        guard let storage = editor.textStorage else { return [] }
        let fullRange = NSRange(location: 0, length: (storage.string as NSString).length)
        var snapshots: [LinkSnapshot] = []
        storage.enumerateAttribute(.link, in: fullRange) { value, range, _ in
            guard let value else { return }
            snapshots.append(LinkSnapshot(
                text: (storage.string as NSString).substring(with: range),
                url: String(describing: value),
                range: range
            ))
        }
        return snapshots
    }
}
