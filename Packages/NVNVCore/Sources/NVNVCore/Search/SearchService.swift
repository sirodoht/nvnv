import Foundation

public enum TextNormalizer {
    public static func normalize(_ value: String) -> String {
        if let bytes = asciiFoldedBytes(value) {
            return String(decoding: bytes, as: UTF8.self)
        }
        return fullyNormalize(value)
    }

    /// Produces the same normalized representation as ``normalize(_:)`` without
    /// retaining an intermediate `String`. Search documents use this for note
    /// bodies, which are commonly much larger than titles.
    public static func normalizedUTF8(_ value: String) -> Data {
        if let bytes = asciiFoldedBytes(value) {
            return Data(bytes)
        }
        return Data(fullyNormalize(value).utf8)
    }

    private static func fullyNormalize(_ value: String) -> String {
        value
            .precomposedStringWithCompatibilityMapping
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
    }

    private static func asciiFoldedBytes(_ value: String) -> [UInt8]? {
        // Turkish and Azerbaijani have locale-specific casing for ASCII "I".
        // Falling back for those locales preserves Foundation's existing
        // locale-sensitive behavior exactly.
        guard asciiCaseFoldingIsLocaleIndependent else { return nil }

        var output: [UInt8] = []
        output.reserveCapacity(value.utf8.count)
        for byte in value.utf8 {
            guard byte < 0x80 else { return nil }
            output.append(byte >= 0x41 && byte <= 0x5A ? byte + 0x20 : byte)
        }
        return output
    }

    private static let asciiCaseFoldingIsLocaleIndependent: Bool = {
        let identifier = Locale.current.identifier.lowercased()
        return !identifier.hasPrefix("tr") && !identifier.hasPrefix("az")
    }()
}

public struct SearchResult: Identifiable, Hashable, Sendable {
    public let note: Note
    public let titleRanges: [NSRange]
    public let bodyRanges: [NSRange]
    public let excerpt: String
    public var id: UUID { note.id }

    public init(note: Note, titleRanges: [NSRange], bodyRanges: [NSRange], excerpt: String? = nil) {
        self.note = note
        self.titleRanges = titleRanges
        self.bodyRanges = bodyRanges
        self.excerpt = excerpt ?? SearchService.excerpt(from: note.body)
    }
}

public struct SearchDocument: Identifiable, Hashable, Sendable {
    public let note: Note
    public let normalizedTitle: String
    public let normalizedTitleBytes: Data
    public let normalizedBodyBytes: Data
    public let excerpt: String
    public var id: UUID { note.id }

    public init(note: Note) {
        self.note = note
        normalizedTitle = TextNormalizer.normalize(note.title)
        normalizedTitleBytes = Data(normalizedTitle.utf8)
        normalizedBodyBytes = TextNormalizer.normalizedUTF8(note.body)
        excerpt = SearchService.excerpt(from: note.body)
    }

    public func replacingMetadata(with note: Note) -> SearchDocument {
        SearchDocument(
            note: note, normalizedTitle: normalizedTitle,
            normalizedTitleBytes: normalizedTitleBytes, normalizedBodyBytes: normalizedBodyBytes,
            excerpt: excerpt
        )
    }

    private init(
        note: Note, normalizedTitle: String, normalizedTitleBytes: Data,
        normalizedBodyBytes: Data, excerpt: String
    ) {
        self.note = note
        self.normalizedTitle = normalizedTitle
        self.normalizedTitleBytes = normalizedTitleBytes
        self.normalizedBodyBytes = normalizedBodyBytes
        self.excerpt = excerpt
    }
}

public enum SearchSubmitAction: Equatable, Sendable {
    case open(UUID)
    case create(String)
    case none
}

public enum SearchService {
    /// Candidate sets at or below this size are cheap enough to search immediately.
    /// Larger full scans retain a short debounce so rapid typing can cancel them
    /// before they consume worker time.
    public static let immediateSearchCandidateLimit = 2_000

    /// Returns true when every document matching `next` must also have matched
    /// `previous`. Search is an AND of substring terms, so each old term must be
    /// contained by at least one new term. This also conservatively handles
    /// transitions into phrases while rejecting phrase splits and query deletion.
    public static func canIncrementallyRefine(from previous: SearchQuery, to next: SearchQuery) -> Bool {
        let previousTerms = normalizedTerms(in: previous)
        let nextTerms = normalizedTerms(in: next)
        guard !previousTerms.isEmpty, !nextTerms.isEmpty else { return false }
        return previousTerms.allSatisfy { previousTerm in
            nextTerms.contains { $0.contains(previousTerm) }
        }
    }

    public static func shouldDebounce(candidateCount: Int) -> Bool {
        candidateCount > immediateSearchCandidateLimit
    }

    public static func search(_ query: SearchQuery, in notes: [Note], sort: NoteSort) -> [SearchResult] {
        search(query, in: notes.map(SearchDocument.init), sort: sort)
    }

    public static func search(_ query: SearchQuery, in documents: [SearchDocument], sort: NoteSort) -> [SearchResult] {
        search(query, in: documents, sort: sort, isCancelled: { false })
    }

    public static func search(
        _ query: SearchQuery, in documents: [SearchDocument], sort: NoteSort,
        isCancelled: @Sendable () -> Bool
    ) -> [SearchResult] {
        let terms = preparedTerms(in: query)
        var found: [SearchResult] = []
        found.reserveCapacity(documents.count)
        for document in documents {
            if isCancelled() { return [] }
            if let result = result(for: document, terms: terms, includeRanges: false) { found.append(result) }
        }
        if isCancelled() { return [] }
        return found.sorted { compare($0.note, $1.note, sort: sort) }
    }

    public static func result(for note: Note, query: SearchQuery) -> SearchResult? {
        result(for: SearchDocument(note: note), query: query)
    }

    public static func result(for document: SearchDocument, query: SearchQuery) -> SearchResult? {
        let terms = preparedTerms(in: query)
        return result(for: document, terms: terms, includeRanges: true)
    }

    private static func normalizedTerms(in query: SearchQuery) -> [String] {
        query.terms.compactMap {
            let normalized = TextNormalizer.normalize($0.value)
            return normalized.isEmpty ? nil : normalized
        }
    }

    private static func preparedTerms(
        in query: SearchQuery
    ) -> [(original: String, bytes: Data)] {
        query.terms.compactMap { term -> (original: String, bytes: Data)? in
            let bytes = TextNormalizer.normalizedUTF8(term.value)
            return bytes.isEmpty ? nil : (term.value, bytes)
        }
    }

    public static func automaticMatch(query: String, documents: [SearchDocument], sort: NoteSort) -> UUID? {
        let needle = TextNormalizer.normalize(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !needle.isEmpty else { return nil }
        let exact = documents.filter { $0.normalizedTitle == needle }
            .sorted { compare($0.note, $1.note, sort: sort) }
        if let first = exact.first { return first.id }
        return documents
            .filter { $0.normalizedTitle.hasPrefix(needle) }
            .sorted {
                if $0.note.title.count != $1.note.title.count { return $0.note.title.count < $1.note.title.count }
                return compare($0.note, $1.note, sort: sort)
            }
            .first?.id
    }

    private static func result(
        for document: SearchDocument,
        terms: [(original: String, bytes: Data)],
        includeRanges: Bool
    ) -> SearchResult? {
        let note = document.note
        if terms.isEmpty { return SearchResult(note: note, titleRanges: [], bodyRanges: [], excerpt: document.excerpt) }
        var titleRanges: [NSRange] = []
        var bodyRanges: [NSRange] = []

        for term in terms {
            let titleMatch = document.normalizedTitleBytes.range(of: term.bytes) != nil
            let bodyMatch = document.normalizedBodyBytes.range(of: term.bytes) != nil
            guard titleMatch || bodyMatch else { return nil }
            if includeRanges {
                titleRanges.append(contentsOf: ranges(of: term.original, in: note.title))
                bodyRanges.append(contentsOf: ranges(of: term.original, in: note.body))
            }
        }
        return SearchResult(note: note, titleRanges: titleRanges, bodyRanges: bodyRanges, excerpt: document.excerpt)
    }

    public static func automaticMatch(query: String, results: [SearchResult], sort: NoteSort) -> UUID? {
        let needle = TextNormalizer.normalize(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !needle.isEmpty else { return nil }
        let exact = results.filter { TextNormalizer.normalize($0.note.title) == needle }
        if let first = exact.first { return first.id }
        return results
            .filter { TextNormalizer.normalize($0.note.title).hasPrefix(needle) }
            .sorted {
                if $0.note.title.count != $1.note.title.count { return $0.note.title.count < $1.note.title.count }
                return compare($0.note, $1.note, sort: sort)
            }
            .first?.id
    }

    public static func submitAction(
        query: String, results: [SearchResult], explicitSelectionID: UUID?, sort: NoteSort
    ) -> SearchSubmitAction {
        if let explicitSelectionID, results.contains(where: { $0.id == explicitSelectionID }) {
            return .open(explicitSelectionID)
        }
        if let automatic = automaticMatch(query: query, results: results, sort: sort) {
            return .open(automatic)
        }
        let title = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? .none : .create(title)
    }

    public static func compare(_ lhs: Note, _ rhs: Note, sort: NoteSort) -> Bool {
        let ordered: Bool
        let equal: Bool
        switch sort.field {
        case .title:
            let result = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
            ordered = result == .orderedAscending
            equal = result == .orderedSame
        case .modified:
            ordered = lhs.modifiedAt < rhs.modifiedAt
            equal = lhs.modifiedAt == rhs.modifiedAt
        case .created:
            ordered = lhs.createdAt < rhs.createdAt
            equal = lhs.createdAt == rhs.createdAt
        }
        if equal {
            let title = TextNormalizer.normalize(lhs.title).localizedCompare(TextNormalizer.normalize(rhs.title))
            if title != .orderedSame { return title == .orderedAscending }
            return lhs.filename.localizedStandardCompare(rhs.filename) == .orderedAscending
        }
        return sort.ascending ? ordered : !ordered
    }

    private static func ranges(of needle: String, in text: String) -> [NSRange] {
        guard !needle.isEmpty else { return [] }
        var output: [NSRange] = []
        var searchRange = text.startIndex..<text.endIndex
        while let range = text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive], range: searchRange) {
            output.append(NSRange(range, in: text))
            if range.isEmpty { break }
            searchRange = range.upperBound..<text.endIndex
        }
        return output
    }

    public static func excerpt(from body: String, limit: Int = 360) -> String {
        var output = ""
        output.reserveCapacity(min(limit, body.count))
        var pendingSpace = false
        var started = false
        var count = 0
        for character in body {
            if character.isWhitespace {
                if started { pendingSpace = true }
                continue
            }
            if pendingSpace, !output.isEmpty {
                guard count < limit else { break }
                output.append(" ")
                count += 1
            }
            pendingSpace = false
            started = true
            guard count < limit else { break }
            output.append(character)
            count += 1
            if count >= limit { break }
        }
        return output
    }
}
