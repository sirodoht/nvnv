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
    public var id: UUID { note.id }
}

public enum SearchService {
    public static func search(_ query: SearchQuery, in notes: [Note], sort: NoteSort) -> [SearchResult] {
        notes.compactMap { result(for: $0, query: query) }.sorted { compare($0.note, $1.note, sort: sort) }
    }

    public static func result(for note: Note, query: SearchQuery) -> SearchResult? {
        if query.isEmpty { return SearchResult(note: note, titleRanges: [], bodyRanges: []) }
        let normalizedTitle = TextNormalizer.normalize(note.title)
        let normalizedBody = TextNormalizer.normalize(note.body)
        var titleRanges: [NSRange] = []
        var bodyRanges: [NSRange] = []

        for term in query.terms {
            let needle = TextNormalizer.normalize(term.value)
            guard !needle.isEmpty else { continue }
            let titleMatch = normalizedTitle.range(of: needle) != nil
            let bodyMatch = normalizedBody.range(of: needle) != nil
            guard titleMatch || bodyMatch else { return nil }
            titleRanges.append(contentsOf: ranges(of: term.value, in: note.title))
            bodyRanges.append(contentsOf: ranges(of: term.value, in: note.body))
        }
        return SearchResult(note: note, titleRanges: titleRanges, bodyRanges: bodyRanges)
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
}
