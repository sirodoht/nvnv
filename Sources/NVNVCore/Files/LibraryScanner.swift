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

        for url in urls {
            let filename = url.lastPathComponent
            guard !filename.hasPrefix("."), url.pathExtension.isEmpty == false,
                  recognizedExtensions.contains(url.pathExtension.lowercased()) else { continue }
            let values = try url.resourceValues(forKeys: keys)
            guard values.isRegularFile == true, values.isSymbolicLink != true, values.isHidden != true else { continue }
            guard let identity = fileIdentity(url) else {
                issues.append(.init(filename: filename, message: "Could not determine a stable file identity."))
                continue
            }
            guard identities.insert(identity).inserted else {
                issues.append(.init(filename: filename, message: "Duplicate hard link ignored."))
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
            let old = cached[filename]
            notes.append(Note(
                id: old?.id ?? UUID(), title: url.deletingPathExtension().lastPathComponent,
                body: body, createdAt: values.creationDate ?? old?.createdAt ?? now,
                modifiedAt: values.contentModificationDate ?? now,
                cursorStart: old?.cursorStart ?? 0, cursorLength: old?.cursorLength ?? 0,
                revision: old?.revision ?? 0, filename: filename,
                lastSavedHash: Hashing.sha256(data), lineEnding: lineEnding, fileIdentity: identity
            ))
        }
        return ScanResult(notes: notes, issues: issues)
    }

    private func fileIdentity(_ url: URL) -> String? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return "\(info.st_dev):\(info.st_ino)"
    }
}
