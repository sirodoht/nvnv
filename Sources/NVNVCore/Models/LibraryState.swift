import Foundation

public struct LibrarySettings: Codable, Equatable, Sendable {
    public var schemaVersion = 3
    public var query = ""
    public var selectedNoteIDs: Set<UUID> = []
    public var selectionKind: SelectionKind = .none
    public var sort = NoteSort()
    public var dividerFraction = 0.36
    public var showModifiedDate = true
    public var showCreatedDate = false
    public var showExcerpts = true
    public var showWordCount = true
    public var confirmDeletion = true
    public var highlightSearch = true
    public var listFontSize = 11.0
    public var editorFontName = ""
    public var editorFontSize = 12.0
    public var softTabs = false
    public var tabWidth = 4
    public var tabIndents = true
    public var recognizedExtensions: Set<String> = ["txt"]
    public var defaultExtension = "txt"

    public init() {}
}

public enum NVNVError: LocalizedError, Equatable, Sendable {
    case invalidLibrary(String)
    case invalidUTF8(String)
    case invalidTitle(String)
    case locked
    case fileChanged(String)
    case fileOperation(path: String, reason: String)
    case cache(String)
    case journal(String)

    public var errorDescription: String? {
        switch self {
        case .invalidLibrary(let reason): "The library cannot be opened: \(reason)"
        case .invalidUTF8(let filename): "\(filename) is not valid UTF-8 and was left untouched."
        case .invalidTitle(let reason): "The title is invalid: \(reason)"
        case .locked: "Another nvnv process is writing this library. It was opened read-only."
        case .fileChanged(let filename): "\(filename) changed outside nvnv. Both versions are safe and must be resolved."
        case .fileOperation(let path, let reason): "The file operation failed for \(path): \(reason). Existing data remains safe."
        case .cache(let reason): "The disposable search cache failed: \(reason). Note files remain safe."
        case .journal(let reason): "Recovery data could not be written: \(reason). Retry before quitting."
        }
    }
}
