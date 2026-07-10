import Foundation
import NVNVCore
import Testing

@Suite("Query parsing and exact search")
struct QueryParserTests {
    @Test func parsesTermsAndPhrases() {
        #expect(SearchQuery(#"project "alpha release""#).terms == [
            .init(value: "project", isPhrase: false),
            .init(value: "alpha release", isPhrase: true),
        ])
    }

    @Test func unmatchedQuoteIsPhrase() {
        #expect(SearchQuery(#"project "alpha release"#).terms.last == .init(value: "alpha release", isPhrase: true))
    }

    @Test func escapedQuoteAndBackslash() {
        #expect(SearchQuery(#""say \"hello\" \\ path""#).terms == [.init(value: #"say "hello" \ path"#, isPhrase: true)])
    }

    @Test func operatorsAndColonAreLiteral() {
        #expect(SearchQuery("tag:value AND OR NOT").terms.map(\.value) == ["tag:value", "AND", "OR", "NOT"])
    }

    @Test func termsCanMatchDifferentFields() {
        let note = Note(title: "Project", body: "Alpha release", filename: "Project.txt")
        #expect(SearchService.search(SearchQuery("project alpha"), in: [note], sort: .init()).map(\.id) == [note.id])
        #expect(SearchService.search(SearchQuery(#""project alpha""#), in: [note], sort: .init()).isEmpty)
    }

    @Test func midwordAndUnicodeNormalizationMatch() {
        let note = Note(title: "Café", body: "interstellar", filename: "Café.txt")
        #expect(SearchService.search(SearchQuery("fé stell"), in: [note], sort: .init()).count == 1)
        #expect(SearchService.search(SearchQuery("CAFE\u{301}"), in: [note], sort: .init()).count == 1)
    }

    @Test func automaticTitleSelectionPrefersExactThenShortestPrefix() {
        let notes = [
            Note(title: "Project Alpha", body: "", filename: "Project Alpha.txt"),
            Note(title: "Project", body: "", filename: "Project.txt"),
            Note(title: "Projector", body: "", filename: "Projector.txt"),
        ]
        let results = SearchService.search(SearchQuery("project"), in: notes, sort: .init(field: .title, ascending: true))
        #expect(SearchService.automaticMatch(query: "project", results: results, sort: .init()) == notes[1].id)
        #expect(SearchService.automaticMatch(query: "pro", results: results, sort: .init()) == notes[1].id)
    }
}
