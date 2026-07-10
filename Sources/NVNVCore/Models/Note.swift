import Foundation

public struct Note: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var title: String
    public var body: String
    public var createdAt: Date
    public var modifiedAt: Date
    public var cursorStart: Int
    public var cursorLength: Int
    public var revision: Int
    public var filename: String
    public var lastSavedHash: String
    public var deletedAt: Date?
    public var lineEnding: LineEnding
    public var fileIdentity: String?

    public init(
        id: UUID = UUID(), title: String, body: String,
        createdAt: Date = .now, modifiedAt: Date = .now,
        cursorStart: Int = 0, cursorLength: Int = 0, revision: Int = 0,
        filename: String, lastSavedHash: String = "", deletedAt: Date? = nil,
        lineEnding: LineEnding = .lf, fileIdentity: String? = nil
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.cursorStart = cursorStart
        self.cursorLength = cursorLength
        self.revision = revision
        self.filename = filename
        self.lastSavedHash = lastSavedHash
        self.deletedAt = deletedAt
        self.lineEnding = lineEnding
        self.fileIdentity = fileIdentity
    }

    public var clampedSelection: NSRange {
        let count = (body as NSString).length
        let start = min(max(cursorStart, 0), count)
        return NSRange(location: start, length: min(max(cursorLength, 0), count - start))
    }
}

public enum LineEnding: String, Codable, Sendable {
    case lf
    case crlf

    public func encoded(_ text: String) -> String {
        self == .crlf ? text.replacingOccurrences(of: "\n", with: "\r\n") : text
    }
}

public enum NoteSortField: String, Codable, CaseIterable, Sendable {
    case title
    case modified
    case created
}

public struct NoteSort: Codable, Equatable, Sendable {
    public var field: NoteSortField
    public var ascending: Bool

    public init(field: NoteSortField = .modified, ascending: Bool = false) {
        self.field = field
        self.ascending = ascending
    }
}

public enum SelectionKind: String, Codable, Sendable {
    case none
    case automatic
    case explicit
}

public struct Conflict: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let noteID: UUID
    public let baseBody: String
    public let appBody: String
    public let fileBody: String
    public let fileHash: String
    public let observedAt: Date

    public init(
        id: UUID = UUID(), noteID: UUID, baseBody: String,
        appBody: String, fileBody: String, fileHash: String, observedAt: Date = .now
    ) {
        self.id = id
        self.noteID = noteID
        self.baseBody = baseBody
        self.appBody = appBody
        self.fileBody = fileBody
        self.fileHash = fileHash
        self.observedAt = observedAt
    }
}
