import Foundation
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
}
