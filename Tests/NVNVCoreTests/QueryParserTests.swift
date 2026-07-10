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

    @Test func returnOpensCurrentMatchOrCreatesUnmatchedTitle() {
        let note = Note(title: "Timeline", body: "history", filename: "Timeline.txt")
        let matching = SearchService.search(SearchQuery("time"), in: [note], sort: .init())
        #expect(SearchService.submitAction(query: "time", results: matching, explicitSelectionID: nil, sort: .init()) == .open(note.id))
        #expect(SearchService.submitAction(query: "Fresh Note", results: [], explicitSelectionID: nil, sort: .init()) == .create("Fresh Note"))
        #expect(SearchService.submitAction(query: "  ", results: [], explicitSelectionID: nil, sort: .init()) == .none)
    }

    @Test func returnIgnoresAnExplicitSelectionThatIsNotInCurrentResults() {
        let staleID = UUID()
        #expect(SearchService.submitAction(
            query: "Brand New", results: [], explicitSelectionID: staleID, sort: .init()
        ) == .create("Brand New"))
    }

    @Test func newlyCreatedExactTitleAppearsWithoutClearingItsFilter() {
        let query = SearchQuery("Brand New")
        #expect(SearchService.search(query, in: [Note](), sort: .init()).isEmpty)
        let created = Note(title: "Brand New", body: "", filename: "Brand New.txt")
        #expect(SearchService.search(query, in: [created], sort: .init()).map(\.id) == [created.id])
    }

    @Test func cachedSearchDocumentsPreserveSemantics() {
        let note = Note(title: "Café Project", body: "An interstellar body", filename: "Café Project.txt")
        let document = SearchDocument(note: note)
        #expect(SearchService.search(SearchQuery("cafe stell"), in: [document], sort: .init()).map(\.id) == [note.id])

        var metadataOnly = note
        metadataOnly.modifiedAt = .now.addingTimeInterval(30)
        let refreshed = document.replacingMetadata(with: metadataOnly)
        #expect(SearchService.search(SearchQuery("interstellar"), in: [refreshed], sort: .init()).first?.note.modifiedAt == metadataOnly.modifiedAt)
    }

    @Test func cancellableSearchStopsBeforePublishingPartialResults() {
        let documents = (0..<100).map {
            SearchDocument(note: Note(title: "Note \($0)", body: "common body", filename: "Note \($0).txt"))
        }
        #expect(SearchService.search(
            SearchQuery("common"), in: documents, sort: .init(), isCancelled: { true }
        ).isEmpty)
    }

    @Test func excerptsAreBoundedWithoutScanningForPresentationLines() {
        let excerpt = SearchService.excerpt(from: String(repeating: "word ", count: 10_000), limit: 80)
        #expect(excerpt.count <= 80)
        #expect(excerpt.hasPrefix("word word"))
    }
}
