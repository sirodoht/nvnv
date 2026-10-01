import Foundation

public struct NamedLibrary: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public let path: String

    public var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
}

/// Application-level registrations, independent of each folder's note data.
public struct LibraryCatalog: Codable, Equatable, Sendable {
    public private(set) var libraries: [NamedLibrary] = []
    public private(set) var activeID: UUID?

    public init() {}

    public static func load(data: Data?, legacyPath: String?) -> LibraryCatalog {
        if let data, let catalog = try? JSONDecoder().decode(Self.self, from: data) {
            return catalog
        }
        var catalog = Self()
        if let legacyPath { catalog.activate(URL(fileURLWithPath: legacyPath)) }
        return catalog
    }

    public var activeLibrary: NamedLibrary? { libraries.first { $0.id == activeID } }

    public static func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    @discardableResult
    public mutating func activate(_ url: URL) -> NamedLibrary {
        let canonical = Self.canonicalURL(url)
        if let existing = libraries.first(where: { Self.canonicalURL($0.url) == canonical }) {
            activeID = existing.id
            return existing
        }
        let entry = NamedLibrary(
            id: UUID(), name: canonical.lastPathComponent.isEmpty ? canonical.path : canonical.lastPathComponent,
            path: canonical.path
        )
        libraries.append(entry)
        activeID = entry.id
        return entry
    }

    public mutating func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = libraries.firstIndex(where: { $0.id == id }) else { return }
        libraries[index].name = trimmed
    }

    public mutating func remove(_ id: UUID) {
        libraries.removeAll { $0.id == id }
        if activeID == id { activeID = nil }
    }
}
