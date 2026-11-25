import NaturalLanguage

public enum WordCounter {
    /// Counts words with the platform's natural-language tokenizer, so text in
    /// scripts that do not separate words with spaces is counted sensibly.
    public static func count(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var count = 0
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { _, _ in
            count += 1
            return true
        }
        return count
    }
}
