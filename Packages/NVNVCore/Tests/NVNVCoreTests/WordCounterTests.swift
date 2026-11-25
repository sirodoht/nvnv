import Testing
@testable import NVNVCore

@Suite("Word counting")
struct WordCounterTests {
    @Test(arguments: [
        ("", 0),
        ("   \n\t ", 0),
        ("one", 1),
        ("one two  three\nfour", 4),
        ("Hello, world! (Really.)", 3),
        ("don't stop", 2),
        ("- item one\n- item two", 4),
        ("café naïve", 2),
    ])
    func countsWords(text: String, expected: Int) {
        #expect(WordCounter.count(text) == expected)
    }

    @Test func countsTextWithoutSpacesBetweenWords() {
        // Whitespace splitting would report one word here.
        #expect(WordCounter.count("我喜欢写笔记") > 1)
    }
}
