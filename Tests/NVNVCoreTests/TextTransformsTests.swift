import Foundation
import NVNVCore
import Testing

@Suite("Plain-text editor transformations")
struct TextTransformsTests {
    @Test func indentsTouchedLines() {
        let result = TextTransforms.indent(text: "one\ntwo", selection: NSRange(location: 0, length: 7), softTabs: true, tabWidth: 2)
        #expect(result.0 == "  one\n  two")
    }

    @Test func outdentsTabsAndSpaces() {
        let result = TextTransforms.outdent(text: "\tone\n  two", selection: NSRange(location: 0, length: 10), tabWidth: 4)
        #expect(result.0 == "one\ntwo")
    }

    @Test func continuesBulletsAndNumbers() {
        #expect(TextTransforms.newlineInsertion(text: "  - item", caret: 8).replacement == "\n  - ")
        #expect(TextTransforms.newlineInsertion(text: "7. item", caret: 7).replacement == "\n8. ")
    }

    @Test func emptyListItemTerminates() {
        let result = TextTransforms.newlineInsertion(text: "- ", caret: 2)
        #expect(result.range == NSRange(location: 0, length: 2))
        #expect(result.replacement.isEmpty)
    }
}
