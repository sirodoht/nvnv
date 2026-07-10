import Foundation

public enum TextNormalizer {
    public static func normalize(_ value: String) -> String {
        value
            .precomposedStringWithCompatibilityMapping
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
    }
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
    public let normalizedBody: String
    public let normalizedTitleBytes: Data
    public let normalizedBodyBytes: Data
    public let excerpt: String
    public var id: UUID { note.id }

    public init(note: Note) {
        self.note = note
        normalizedTitle = TextNormalizer.normalize(note.title)
        normalizedBody = TextNormalizer.normalize(note.body)
        normalizedTitleBytes = Data(normalizedTitle.utf8)
        normalizedBodyBytes = Data(normalizedBody.utf8)
        excerpt = SearchService.excerpt(from: note.body)
    }

    public func replacingMetadata(with note: Note) -> SearchDocument {
        SearchDocument(
            note: note, normalizedTitle: normalizedTitle,
            normalizedBody: normalizedBody, normalizedTitleBytes: normalizedTitleBytes,
            normalizedBodyBytes: normalizedBodyBytes, excerpt: excerpt
        )
    }

    private init(
        note: Note, normalizedTitle: String, normalizedBody: String,
        normalizedTitleBytes: Data, normalizedBodyBytes: Data, excerpt: String
    ) {
        self.note = note
        self.normalizedTitle = normalizedTitle
        self.normalizedBody = normalizedBody
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
        let terms = query.terms.compactMap { term -> (original: String, normalized: String, bytes: Data)? in
            let normalized = TextNormalizer.normalize(term.value)
            return normalized.isEmpty ? nil : (term.value, normalized, Data(normalized.utf8))
        }
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
        let terms = query.terms.compactMap { term -> (original: String, normalized: String, bytes: Data)? in
            let normalized = TextNormalizer.normalize(term.value)
            return normalized.isEmpty ? nil : (term.value, normalized, Data(normalized.utf8))
        }
        return result(for: document, terms: terms, includeRanges: true)
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
        terms: [(original: String, normalized: String, bytes: Data)],
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
