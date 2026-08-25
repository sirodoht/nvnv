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

    @Test func asciiNormalizationProducesCompactLowercaseUTF8() {
        let input = "ASCII Title 123!?"
        let expected = Data("ascii title 123!?".utf8)
        #expect(TextNormalizer.normalize(input) == "ascii title 123!?")
        #expect(TextNormalizer.normalizedUTF8(input) == expected)

        let note = Note(title: "PROJECT ALPHA", body: "A FAST ASCII BODY", filename: "PROJECT ALPHA.txt")
        let document = SearchDocument(note: note)
        #expect(SearchService.search(SearchQuery("project fast"), in: [document], sort: .init()).map(\.id) == [note.id])
    }

    @Test func unicodeNormalizationPreservesCompatibilityAndDiacriticSemantics() {
        let decomposedCafe = "Cafe\u{301}"
        let representativeText = ["", "plain ASCII", decomposedCafe, "CAFÉ", "ＷＩＤＴＨ", "naïve — straße"]
        for text in representativeText {
            #expect(TextNormalizer.normalizedUTF8(text) == Data(TextNormalizer.normalize(text).utf8))
        }

        let note = Note(
            title: "ＷＩＤＴＨ Café", body: "naïve coöperation and straße",
            filename: "Unicode.txt"
        )
        let document = SearchDocument(note: note)

        #expect(TextNormalizer.normalize(decomposedCafe) == TextNormalizer.normalize("CAFÉ"))
        #expect(TextNormalizer.normalizedUTF8(decomposedCafe) == TextNormalizer.normalizedUTF8("CAFÉ"))
        #expect(SearchService.search(SearchQuery("width cafe"), in: [document], sort: .init()).map(\.id) == [note.id])
        #expect(
            SearchService.search(SearchQuery("naive cooperation"), in: [document], sort: .init()).map(\.id) == [note.id]
        )
        #expect(SearchService.search(SearchQuery("STRASSE"), in: [document], sort: .init()).map(\.id) == [note.id])
    }

    @Test func mixedASCIIAndUnicodeBodiesUseTheSameSearchSemantics() {
        let note = Note(
            title: "Mixed Note", body: "ordinary ASCII prefix — CAFÉ ＷＡＴＥＲ suffix",
            filename: "Mixed Note.txt"
        )
        let document = SearchDocument(note: note)
        #expect(SearchService.search(SearchQuery("ordinary"), in: [document], sort: .init()).map(\.id) == [note.id])
        #expect(SearchService.search(SearchQuery("cafe water"), in: [document], sort: .init()).map(\.id) == [note.id])
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
        #expect(refreshed.normalizedTitleBytes == document.normalizedTitleBytes)
        #expect(refreshed.normalizedBodyBytes == document.normalizedBodyBytes)
    }

    @Test func cachedDocumentsRetainOnlyOneNormalizedBodyRepresentation() {
        let document = SearchDocument(note: Note(title: "Title", body: "A sizeable body", filename: "Title.txt"))
        let storedPropertyNames = Set(Mirror(reflecting: document).children.compactMap(\.label))
        #expect(storedPropertyNames.contains("normalizedBodyBytes"))
        #expect(!storedPropertyNames.contains("normalizedBody"))
    }

    @Test func cancellableSearchStopsBeforePublishingPartialResults() {
        let documents = (0..<100).map {
            SearchDocument(note: Note(title: "Note \($0)", body: "common body", filename: "Note \($0).txt"))
        }
        #expect(SearchService.search(
            SearchQuery("common"), in: documents, sort: .init(), isCancelled: { true }
        ).isEmpty)
    }

    @Test func refinementEligibilityAcceptsOnlyMonotonicConstraints() {
        #expect(SearchService.canIncrementallyRefine(
            from: SearchQuery("pro"), to: SearchQuery("project")
        ))
        #expect(SearchService.canIncrementallyRefine(
            from: SearchQuery("project alpha"), to: SearchQuery("project alphabet release")
        ))
        #expect(SearchService.canIncrementallyRefine(
            from: SearchQuery("cafe"), to: SearchQuery("CAFÉ noir")
        ))
        #expect(SearchService.canIncrementallyRefine(
            from: SearchQuery("foo bar"), to: SearchQuery(#""foo bar""#)
        ))

        #expect(!SearchService.canIncrementallyRefine(
            from: SearchQuery("project"), to: SearchQuery("pro")
        ))
        #expect(!SearchService.canIncrementallyRefine(
            from: SearchQuery("project"), to: SearchQuery("prospect")
        ))
        #expect(!SearchService.canIncrementallyRefine(
            from: SearchQuery(#""foo bar""#), to: SearchQuery("foo bar")
        ))
        #expect(!SearchService.canIncrementallyRefine(
            from: SearchQuery("project"), to: SearchQuery("   ")
        ))
        #expect(!SearchService.canIncrementallyRefine(
            from: SearchQuery(""), to: SearchQuery("project")
        ))
    }

    @Test func incrementalRefinementProducesExactlyTheFullSearchResults() {
        let notes = [
            Note(title: "Project Alphabet", body: "Release plan", filename: "Project Alphabet.txt"),
            Note(title: "Project", body: "Alpha release", filename: "Project.txt"),
            Note(title: "Unrelated", body: "Project alpha is mentioned here", filename: "Unrelated.txt"),
            Note(title: "Project Beta", body: "Archived", filename: "Project Beta.txt"),
        ]
        let documents = notes.map(SearchDocument.init)
        let previous = SearchQuery("pro")
        let next = SearchQuery(#"project "alpha""#)
        #expect(SearchService.canIncrementallyRefine(from: previous, to: next))

        let previousIDs = Set(SearchService.search(previous, in: documents, sort: .init()).map(\.id))
        let candidates = documents.filter { previousIDs.contains($0.id) }
        let incremental = SearchService.search(next, in: candidates, sort: .init()).map(\.id)
        let full = SearchService.search(next, in: documents, sort: .init()).map(\.id)
        #expect(incremental == full)
    }

    @Test func broadSearchesStabilizeWhileSmallRefinementsRunImmediately() {
        #expect(!SearchService.shouldDebounce(candidateCount: 0))
        #expect(!SearchService.shouldDebounce(candidateCount: SearchService.immediateSearchCandidateLimit))
        #expect(SearchService.shouldDebounce(candidateCount: SearchService.immediateSearchCandidateLimit + 1))
        #expect(SearchService.broadSearchStabilizationDelay == .milliseconds(100))
    }

    @Test func excerptsAreBoundedWithoutScanningForPresentationLines() {
        let excerpt = SearchService.excerpt(from: String(repeating: "word ", count: 10_000), limit: 80)
        #expect(excerpt.count <= 80)
        #expect(excerpt.hasPrefix("word word"))
    }

    @Test func metadataReplacementRebuildsDerivedContentWhenBodyChanges() {
        let original = Note(title: "Draft", body: "x", filename: "Draft.txt")
        let document = SearchDocument(note: original)
        var cleared = original
        cleared.body = ""
        cleared.revision += 1

        let replaced = document.replacingMetadata(with: cleared)

        #expect(replaced.note.body.isEmpty)
        #expect(replaced.excerpt.isEmpty)
        #expect(replaced.normalizedBodyBytes.isEmpty)
        #expect(SearchService.result(for: replaced, query: SearchQuery("x")) == nil)
    }
}
