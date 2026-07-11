import Darwin
import Foundation

public struct ScanIssue: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let filename: String
    public let message: String
}

public struct ScanResult: Sendable {
    public let notes: [Note]
    public let issues: [ScanIssue]

    public init(notes: [Note], issues: [ScanIssue]) {
        self.notes = notes
        self.issues = issues
    }
}

public struct LibraryScanner: Sendable {
    public init() {}

    public func validate(_ directory: URL, requireWritable: Bool = true) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw NVNVError.invalidLibrary("the selected path is not a directory")
        }
        guard FileManager.default.isReadableFile(atPath: directory.path) else {
            throw NVNVError.invalidLibrary("the directory is not readable")
        }
        if requireWritable, !FileManager.default.isWritableFile(atPath: directory.path) {
            throw NVNVError.invalidLibrary("the directory is not writable")
        }
        let trash = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash").standardizedFileURL.path
        if directory.standardizedFileURL.path.hasPrefix(trash) {
            throw NVNVError.invalidLibrary("directories inside Trash are not supported")
        }
    }

    public func scan(
        directory: URL, recognizedExtensions: Set<String>, cached: [String: Note] = [:],
        now: Date = .now
    ) throws -> ScanResult {
        try validate(directory, requireWritable: false)
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .isHiddenKey, .creationDateKey, .contentModificationDateKey]
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsSubdirectoryDescendants]
        ).sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        var notes: [Note] = []
        var issues: [ScanIssue] = []
        var identities: Set<String> = []
        var cachedByIdentity: [String: Note] = [:]
        for note in cached.values {
            if let identity = note.fileIdentity, cachedByIdentity[identity] == nil {
                cachedByIdentity[identity] = note
            }
        }

        for url in urls {
            let filename = url.lastPathComponent
            guard !filename.hasPrefix("."), url.pathExtension.isEmpty == false,
                  recognizedExtensions.contains(url.pathExtension.lowercased()) else { continue }
            let values = try url.resourceValues(forKeys: keys)
            guard values.isRegularFile == true, values.isSymbolicLink != true, values.isHidden != true else { continue }
            guard let metadata = fileMetadata(url) else {
                issues.append(.init(filename: filename, message: "Could not determine a stable file identity."))
                continue
            }
            let identity = metadata.identity
            guard identities.insert(identity).inserted else {
                issues.append(.init(filename: filename, message: "Duplicate hard link ignored."))
                continue
            }
            let old = cached[filename] ?? cachedByIdentity[identity]
            if let old, metadata.matches(old) {
                notes.append(Note(
                    id: old.id, title: url.deletingPathExtension().lastPathComponent,
                    body: old.body, createdAt: old.createdAt,
                    modifiedAt: metadata.modificationDate,
                    cursorStart: old.cursorStart, cursorLength: old.cursorLength,
                    revision: old.revision, filename: filename,
                    lastSavedHash: old.lastSavedHash, lineEnding: old.lineEnding,
                    fileIdentity: identity, fileSize: metadata.size,
                    fileModificationSeconds: metadata.modificationSeconds,
                    fileModificationNanoseconds: metadata.modificationNanoseconds,
                    fileStatusChangeSeconds: metadata.statusChangeSeconds,
                    fileStatusChangeNanoseconds: metadata.statusChangeNanoseconds
                ))
                continue
            }
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            let payload = data.starts(with: [0xEF, 0xBB, 0xBF]) ? data.dropFirst(3) : data[...]
            guard var rawBody = String(data: payload, encoding: .utf8) else {
                issues.append(.init(filename: filename, message: "Invalid UTF-8; file was left untouched."))
                continue
            }
            if rawBody.contains("\0") {
                rawBody = rawBody.replacingOccurrences(of: "\0", with: "\u{FFFD}")
                issues.append(.init(filename: filename, message: "NUL characters are displayed as replacement characters."))
            }
            let lineEnding: LineEnding = rawBody.contains("\r\n") ? .crlf : .lf
            let body = rawBody.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            notes.append(Note(
                id: old?.id ?? UUID(), title: url.deletingPathExtension().lastPathComponent,
                body: body, createdAt: values.creationDate ?? old?.createdAt ?? now,
                modifiedAt: metadata.modificationDate,
                cursorStart: old?.cursorStart ?? 0, cursorLength: old?.cursorLength ?? 0,
                revision: old?.revision ?? 0, filename: filename,
                lastSavedHash: Hashing.sha256(data), lineEnding: lineEnding, fileIdentity: identity,
                fileSize: metadata.size,
                fileModificationSeconds: metadata.modificationSeconds,
                fileModificationNanoseconds: metadata.modificationNanoseconds,
                fileStatusChangeSeconds: metadata.statusChangeSeconds,
                fileStatusChangeNanoseconds: metadata.statusChangeNanoseconds
            ))
        }
        return ScanResult(notes: notes, issues: issues)
    }

    /// Scans only the supplied immediate children of `directory`. Missing paths
    /// represent deletions and are omitted from the result. Cached notes outside
    /// the batch seed the identity set so newly-created hard links are rejected
    /// consistently with a complete directory scan.
    public func scan(
        directory: URL, paths: Set<URL>, recognizedExtensions: Set<String>,
        cached: [String: Note] = [:], now: Date = .now
    ) throws -> ScanResult {
        try validate(directory, requireWritable: false)
        let root = directory.standardizedFileURL
        let urls = paths.map(\.standardizedFileURL).filter {
            $0.deletingLastPathComponent() == root
        }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        let targetedFilenames = Set(urls.map(\.lastPathComponent))
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .isHiddenKey, .creationDateKey, .contentModificationDateKey]
        let unchangedIdentities = Set(cached.values.compactMap { note in
            targetedFilenames.contains(note.filename) ? nil : note.fileIdentity
        })
        var batchIdentities: Set<String> = []
        var cachedByIdentity: [String: Note] = [:]
        for note in cached.values {
            if let identity = note.fileIdentity, cachedByIdentity[identity] == nil {
                cachedByIdentity[identity] = note
            }
        }
        var notes: [Note] = []
        var issues: [ScanIssue] = []
        for url in urls {
            let filename = url.lastPathComponent
            guard !filename.hasPrefix("."), !url.pathExtension.isEmpty,
                  recognizedExtensions.contains(url.pathExtension.lowercased()),
                  FileManager.default.fileExists(atPath: url.path) else { continue }
            let values = try url.resourceValues(forKeys: keys)
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  values.isHidden != true else { continue }
            guard let metadata = fileMetadata(url) else {
                issues.append(.init(filename: filename, message: "Could not determine a stable file identity."))
                continue
            }
            guard batchIdentities.insert(metadata.identity).inserted else {
                issues.append(.init(filename: filename, message: "Duplicate hard link ignored."))
                continue
            }
            if unchangedIdentities.contains(metadata.identity),
               let owner = cachedByIdentity[metadata.identity],
               FileManager.default.fileExists(atPath: root.appendingPathComponent(owner.filename).path) {
                issues.append(.init(filename: filename, message: "Duplicate hard link ignored."))
                continue
            }
            let old = cached[filename] ?? cachedByIdentity[metadata.identity]
            if let old, metadata.matches(old) {
                notes.append(Note(
                    id: old.id, title: url.deletingPathExtension().lastPathComponent,
                    body: old.body, createdAt: old.createdAt, modifiedAt: metadata.modificationDate,
                    cursorStart: old.cursorStart, cursorLength: old.cursorLength,
                    revision: old.revision, filename: filename, lastSavedHash: old.lastSavedHash,
                    lineEnding: old.lineEnding, fileIdentity: metadata.identity, fileSize: metadata.size,
                    fileModificationSeconds: metadata.modificationSeconds,
                    fileModificationNanoseconds: metadata.modificationNanoseconds,
                    fileStatusChangeSeconds: metadata.statusChangeSeconds,
                    fileStatusChangeNanoseconds: metadata.statusChangeNanoseconds
                ))
                continue
            }
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            let payload = data.starts(with: [0xEF, 0xBB, 0xBF]) ? data.dropFirst(3) : data[...]
            guard var rawBody = String(data: payload, encoding: .utf8) else {
                issues.append(.init(filename: filename, message: "Invalid UTF-8; file was left untouched."))
                continue
            }
            if rawBody.contains("\0") {
                rawBody = rawBody.replacingOccurrences(of: "\0", with: "\u{FFFD}")
                issues.append(.init(filename: filename, message: "NUL characters are displayed as replacement characters."))
            }
            let lineEnding: LineEnding = rawBody.contains("\r\n") ? .crlf : .lf
            let body = rawBody.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            notes.append(Note(
                id: old?.id ?? UUID(), title: url.deletingPathExtension().lastPathComponent,
                body: body, createdAt: values.creationDate ?? old?.createdAt ?? now,
                modifiedAt: metadata.modificationDate, cursorStart: old?.cursorStart ?? 0,
                cursorLength: old?.cursorLength ?? 0, revision: old?.revision ?? 0,
                filename: filename, lastSavedHash: Hashing.sha256(data), lineEnding: lineEnding,
                fileIdentity: metadata.identity, fileSize: metadata.size,
                fileModificationSeconds: metadata.modificationSeconds,
                fileModificationNanoseconds: metadata.modificationNanoseconds,
                fileStatusChangeSeconds: metadata.statusChangeSeconds,
                fileStatusChangeNanoseconds: metadata.statusChangeNanoseconds
            ))
        }
        return ScanResult(notes: notes, issues: issues)
    }

    private func fileMetadata(_ url: URL) -> ScannedFileMetadata? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return ScannedFileMetadata(
            identity: "\(info.st_dev):\(info.st_ino)",
            size: Int64(info.st_size),
            modificationSeconds: Int64(info.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(info.st_mtimespec.tv_nsec),
            statusChangeSeconds: Int64(info.st_ctimespec.tv_sec),
            statusChangeNanoseconds: Int64(info.st_ctimespec.tv_nsec)
        )
    }
}

private struct ScannedFileMetadata {
    let identity: String
    let size: Int64
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
    let statusChangeSeconds: Int64
    let statusChangeNanoseconds: Int64

    var modificationDate: Date {
        Date(timeIntervalSince1970: Double(modificationSeconds) + Double(modificationNanoseconds) / 1_000_000_000)
    }

    func matches(_ note: Note) -> Bool {
        note.fileIdentity == identity
            && note.fileSize == size
            && note.fileModificationSeconds == modificationSeconds
            && note.fileModificationNanoseconds == modificationNanoseconds
            && note.fileStatusChangeSeconds == statusChangeSeconds
            && note.fileStatusChangeNanoseconds == statusChangeNanoseconds
    }
}
