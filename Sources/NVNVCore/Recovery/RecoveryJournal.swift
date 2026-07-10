import Darwin
import Foundation

public struct JournalEntry: Identifiable, Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case create, edit, rename, delete }

    public let schemaVersion: Int
    public let id: UUID
    public let noteID: UUID
    public let kind: Kind
    public let baseHash: String?
    public let filename: String
    public let intendedFilename: String
    public let body: String
    public let revision: Int
    public let createdAt: Date

    public init(
        schemaVersion: Int = 1, id: UUID = UUID(), noteID: UUID, kind: Kind,
        baseHash: String?, filename: String, intendedFilename: String,
        body: String, revision: Int, createdAt: Date = .now
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.noteID = noteID
        self.kind = kind
        self.baseHash = baseHash
        self.filename = filename
        self.intendedFilename = intendedFilename
        self.body = body
        self.revision = revision
        self.createdAt = createdAt
    }
}

public actor RecoveryJournal {
    private let directory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(directory: URL) throws {
        self.directory = directory
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func record(_ entry: JournalEntry) throws {
        Failpoint.trigger("before-journal-durability")
        let data = try encoder.encode(entry)
        try data.write(to: url(for: entry.id), options: [.atomic])
        try syncDirectory()
        Failpoint.trigger("after-journal-durability")
    }

    public func remove(_ id: UUID) throws {
        let target = url(for: id)
        if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
        try syncDirectory()
    }

    public func pending() throws -> [JournalEntry] {
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        return try urls.map { url in
            let entry = try decoder.decode(JournalEntry.self, from: Data(contentsOf: url))
            guard entry.schemaVersion == 1 else { throw NVNVError.journal("unsupported journal schema \(entry.schemaVersion)") }
            return entry
        }.sorted { $0.createdAt < $1.createdAt }
    }

    private func url(for id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).json") }

    private func syncDirectory() throws {
        let fd = open(directory.path, O_RDONLY)
        guard fd >= 0 else { throw NVNVError.journal(String(cString: strerror(errno))) }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw NVNVError.journal(String(cString: strerror(errno))) }
    }
}
