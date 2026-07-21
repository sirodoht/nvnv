import AppKit
import Testing
@testable import nvnv

@Suite("Search field inline completion")
struct SearchFieldCompletionTests {
    @Test func appendsAndSelectsOnlyTheUntypedTitleSuffix() {
        let presentation = SearchFieldCompletion.presentation(
            typedText: "masa",
            completionTitle: "masala chai recipe"
        )

        #expect(presentation.string == "masala chai recipe")
        #expect(presentation.completionRange == NSRange(location: 4, length: 14))
    }

    @Test func preservesTheUsersCasingInTheTypedPrefix() {
        let presentation = SearchFieldCompletion.presentation(
            typedText: "masa",
            completionTitle: "Masala Chai"
        )

        #expect(presentation.string == "masala Chai")
        #expect(presentation.completionRange == NSRange(location: 4, length: 7))
    }

    @Test func usesFieldEditorUTF16Offsets() {
        let presentation = SearchFieldCompletion.presentation(
            typedText: "🫖",
            completionTitle: "🫖 chai"
        )

        #expect(presentation.string == "🫖 chai")
        #expect(presentation.completionRange == NSRange(location: 2, length: 5))
    }

    @Test func omitsACompletionRangeForAnExactTitle() {
        let presentation = SearchFieldCompletion.presentation(
            typedText: "Masala Chai",
            completionTitle: "Masala Chai"
        )

        #expect(presentation.string == "Masala Chai")
        #expect(presentation.completionRange == nil)
    }

    @Test func leavesTypedTextAloneWithoutAMatchingTitle() {
        let presentation = SearchFieldCompletion.presentation(
            typedText: "ginger",
            completionTitle: nil
        )

        #expect(presentation.string == "ginger")
        #expect(presentation.completionRange == nil)
    }

    @MainActor
    @Test func backspaceDoesNotImmediatelyRestoreADeletedCompletion() {
        var changedText: String?
        let field = NSTextField()
        let editor = NSTextView()
        let searchField = CompletingSearchField(
            text: "degrowth ",
            completionTitle: "degrowth 234",
            placeholder: "",
            focusGeneration: 0,
            onChange: { changedText = $0 },
            onSubmit: {},
            onMove: { _ in },
            onEscape: {},
            onFocusChange: { _ in }
        )
        let coordinator = searchField.makeCoordinator()

        editor.string = "degrowth 234"
        editor.setSelectedRange(NSRange(location: 9, length: 3))
        let handled = coordinator.control(
            field,
            textView: editor,
            doCommandBy: #selector(NSResponder.deleteBackward(_:))
        )
        #expect(!handled)

        editor.string = "degrowth "
        editor.setSelectedRange(NSRange(location: 9, length: 0))
        coordinator.controlTextDidChange(Notification(
            name: NSControl.textDidChangeNotification,
            object: field,
            userInfo: ["NSFieldEditor": editor]
        ))
        coordinator.updateField(field, text: "degrowth ", completionTitle: "degrowth 234")

        #expect(changedText == "degrowth ")
        #expect(field.stringValue == "degrowth ")

        let secondHandled = coordinator.control(
            field,
            textView: editor,
            doCommandBy: #selector(NSResponder.deleteBackward(_:))
        )
        #expect(!secondHandled)

        editor.string = "degrowth"
        editor.setSelectedRange(NSRange(location: 8, length: 0))
        coordinator.controlTextDidChange(Notification(
            name: NSControl.textDidChangeNotification,
            object: field,
            userInfo: ["NSFieldEditor": editor]
        ))
        coordinator.updateField(field, text: "degrowth", completionTitle: "degrowth 234")

        #expect(changedText == "degrowth")
        #expect(field.stringValue == "degrowth")
    }
}
