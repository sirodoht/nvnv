import Foundation
import NVNVCore
import Testing

@Suite("Plain-text editor transformations")
struct TextTransformsTests {
    @Test func tabInsertionUsesTheNextSoftTabStopOrOneHardTab() {
        let soft = TextTransforms.tabInsertion(
            text: "ab", caret: 2, softTabs: true, tabWidth: 4
        )
        #expect(soft.range == NSRange(location: 2, length: 0))
        #expect(soft.replacement == "  ")

        let hard = TextTransforms.tabInsertion(
            text: "ab", caret: 2, softTabs: false, tabWidth: 4
        )
        #expect(hard.range == NSRange(location: 2, length: 0))
        #expect(hard.replacement == "\t")
    }

    @Test func indentsTouchedLines() {
        let result = TextTransforms.indent(text: "one\ntwo", selection: NSRange(location: 0, length: 7), softTabs: true, tabWidth: 2)
        #expect(result.0 == "  one\n  two")
    }

    @Test func indentAtCaretDoesNotAffectOrSelectTheNextLine() {
        let result = TextTransforms.indent(
            text: "one\ntwo\nthree",
            selection: NSRange(location: 4, length: 0),
            softTabs: true,
            tabWidth: 2
        )
        #expect(result.0 == "one\n  two\nthree")
        #expect(result.1 == NSRange(location: 6, length: 0))
    }

    @Test func indentPreservesSingleLineSelectionWithoutTouchingNextLine() {
        let result = TextTransforms.indent(
            text: "one\ntwo\nthree",
            selection: NSRange(location: 5, length: 1),
            softTabs: true,
            tabWidth: 2
        )
        #expect(result.0 == "one\n  two\nthree")
        #expect(result.1 == NSRange(location: 7, length: 1))
    }

    @Test func indentExcludesFollowingLineWhenSelectionEndsAtItsStart() {
        let result = TextTransforms.indent(
            text: "one\ntwo\nthree",
            selection: NSRange(location: 0, length: 4),
            softTabs: true,
            tabWidth: 2
        )
        #expect(result.0 == "  one\ntwo\nthree")
        #expect(result.1 == NSRange(location: 2, length: 4))
    }

    @Test func indentInEmptyDocumentInsertsOneIndent() {
        let result = TextTransforms.indent(
            text: "",
            selection: NSRange(location: 0, length: 0),
            softTabs: true,
            tabWidth: 2
        )
        #expect(result.0 == "  ")
        #expect(result.1 == NSRange(location: 2, length: 0))
    }

    @Test func outdentsTabsAndSpaces() {
        let result = TextTransforms.outdent(text: "\tone\n  two", selection: NSRange(location: 0, length: 10), tabWidth: 4)
        #expect(result.0 == "one\ntwo")
    }

    @Test func outdentAtCaretPreservesCollapsedSelectionAndFollowingLine() {
        let result = TextTransforms.outdent(
            text: "one\n    two\n    three",
            selection: NSRange(location: 8, length: 0),
            tabWidth: 4
        )
        #expect(result.0 == "one\ntwo\n    three")
        #expect(result.1 == NSRange(location: 4, length: 0))
    }

    @Test func outdentPreservesLogicalMultilineSelection() {
        let result = TextTransforms.outdent(
            text: "\tone\n  two\nthree",
            selection: NSRange(location: 0, length: 10),
            tabWidth: 4
        )
        #expect(result.0 == "one\ntwo\nthree")
        #expect(result.1 == NSRange(location: 0, length: 7))
    }

    @Test func continuesBulletsAndNumbers() {
        #expect(TextTransforms.newlineInsertion(text: "  - item", caret: 8).replacement == "\n  - ")
        #expect(TextTransforms.newlineInsertion(text: "7. item", caret: 7).replacement == "\n8. ")
    }

    @Test func manuallyEnteredEmptyListMarkersArePreserved() {
        let cases = [
            (text: "- ", expected: "- \n"),
            (text: "1. ", expected: "1. \n"),
            (text: "  * ", expected: "  * \n  "),
            (text: "  7. ", expected: "  7. \n  "),
        ]
        for value in cases {
            let result = TextTransforms.newlineInsertion(
                text: value.text,
                caret: (value.text as NSString).length
            )
            let output = (value.text as NSString).replacingCharacters(
                in: result.range,
                with: result.replacement
            )
            #expect(output == value.expected)
        }
    }

    @Test func emptyContinuedListItemsTerminate() {
        let cases = [
            (text: "- item\n- ", expected: "- item\n"),
            (text: "1. item\n2. ", expected: "1. item\n"),
            (text: "  * item\n  * ", expected: "  * item\n  "),
            (text: "  7. item\n  8. ", expected: "  7. item\n  "),
        ]
        for value in cases {
            let result = TextTransforms.newlineInsertion(
                text: value.text,
                caret: (value.text as NSString).length
            )
            let output = (value.text as NSString).replacingCharacters(
                in: result.range,
                with: result.replacement
            )
            #expect(output == value.expected)
        }
    }

    @Test func emptyMarkerWithoutMatchingPreviousItemIsPreserved() {
        let cases = [
            (text: "paragraph\n1. ", expected: "paragraph\n1. \n"),
            (text: "1. item\n3. ", expected: "1. item\n3. \n"),
            (text: "- item\n* ", expected: "- item\n* \n"),
            (text: "  1. item\n2. ", expected: "  1. item\n2. \n"),
        ]
        for value in cases {
            let result = TextTransforms.newlineInsertion(
                text: value.text,
                caret: (value.text as NSString).length
            )
            let output = (value.text as NSString).replacingCharacters(
                in: result.range,
                with: result.replacement
            )
            #expect(output == value.expected)
        }
    }
}
