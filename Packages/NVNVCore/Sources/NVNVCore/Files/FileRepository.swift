import Darwin
import Foundation

public enum FileWriteResult: Sendable {
    case saved(FileWriteMetadata)
    case conflict(currentData: Data, currentHash: String)
}

public struct FileWriteMetadata: Sendable {
    public let hash: String
    public let modifiedAt: Date
    public let identity: String?
    public let fileSize: Int64?
    public let modificationSeconds: Int64?
    public let modificationNanoseconds: Int64?
    public let statusChangeSeconds: Int64?
    public let statusChangeNanoseconds: Int64?
}

public actor FileRepository {
    private let libraryURL: URL

    public init(libraryURL: URL) { self.libraryURL = libraryURL }

    public func create(filename: String, body: String, lineEnding: LineEnding = .lf) throws -> FileWriteResult {
        let destination = libraryURL.appendingPathComponent(filename)
        let bytes = Data(lineEnding.encoded(body).utf8)
        let descriptor = open(destination.path, O_CREAT | O_EXCL | O_WRONLY, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            let reason = errno == EEXIST ? "a file already exists" : String(cString: strerror(errno))
            throw NVNVError.fileOperation(path: filename, reason: reason)
        }
        var isOpen = true
        defer {
            if isOpen { close(descriptor) }
        }
        do {
            try bytes.withUnsafeBytes { rawBuffer in
                guard let base = rawBuffer.baseAddress else { return }
                var offset = 0
                while offset < rawBuffer.count {
                    let count = Darwin.write(descriptor, base.advanced(by: offset), rawBuffer.count - offset)
                    guard count >= 0 else {
                        throw NVNVError.fileOperation(path: filename, reason: String(cString: strerror(errno)))
                    }
                    offset += count
                }
            }
            guard fsync(descriptor) == 0 else {
                throw NVNVError.fileOperation(path: filename, reason: String(cString: strerror(errno)))
            }
            close(descriptor)
            isOpen = false
            try syncDirectory()
            return .saved(try writeMetadata(for: destination, hash: Hashing.sha256(bytes)))
        } catch {
            if isOpen { close(descriptor); isOpen = false }
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    public func save(note: Note) throws -> FileWriteResult {
        try replace(
            destination: libraryURL.appendingPathComponent(note.filename), body: note.body,
            lineEnding: note.lineEnding, expectedHash: note.lastSavedHash
        )
    }

    public func forceSave(note: Note, expectedHash: String) throws -> FileWriteResult {
        try replace(
            destination: libraryURL.appendingPathComponent(note.filename), body: note.body,
            lineEnding: note.lineEnding, expectedHash: expectedHash
        )
    }

    public func rename(note: Note, to filename: String) throws -> URL {
        let source = libraryURL.appendingPathComponent(note.filename)
        let destination = libraryURL.appendingPathComponent(filename)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw NVNVError.fileOperation(path: filename, reason: "a file already exists")
        }
        if source.lastPathComponent.caseInsensitiveCompare(destination.lastPathComponent) == .orderedSame {
            let temporary = libraryURL.appendingPathComponent(".nvnv-rename-\(UUID().uuidString)")
            try FileManager.default.moveItem(at: source, to: temporary)
            do { try FileManager.default.moveItem(at: temporary, to: destination) }
            catch {
                try? FileManager.default.moveItem(at: temporary, to: source)
                throw error
            }
        } else {
            try FileManager.default.moveItem(at: source, to: destination)
        }
        var values = URLResourceValues()
        values.contentModificationDate = .now
        var mutable = destination
        try mutable.setResourceValues(values)
        try syncDirectory()
        return destination
    }

    public func trash(note: Note) throws -> URL? {
        let source = libraryURL.appendingPathComponent(note.filename)
        var resulting: NSURL?
        try FileManager.default.trashItem(at: source, resultingItemURL: &resulting)
        try syncDirectory()
        return resulting as URL?
    }

    public func data(for filename: String) throws -> Data {
        try Data(contentsOf: libraryURL.appendingPathComponent(filename))
    }

    private func replace(destination: URL, body: String, lineEnding: LineEnding, expectedHash: String?) throws -> FileWriteResult {
        Failpoint.trigger("before-temporary-write")
        let bytes = Data(lineEnding.encoded(body).utf8)
        let temporary = libraryURL.appendingPathComponent(".nvnv-write-\(UUID().uuidString).tmp")
        let fd = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw NVNVError.fileOperation(path: destination.lastPathComponent, reason: String(cString: strerror(errno))) }
        do {
            try bytes.withUnsafeBytes { rawBuffer in
                guard let base = rawBuffer.baseAddress else { return }
                var offset = 0
                while offset < rawBuffer.count {
                    let count = Darwin.write(fd, base.advanced(by: offset), rawBuffer.count - offset)
                    guard count >= 0 else { throw NVNVError.fileOperation(path: destination.lastPathComponent, reason: String(cString: strerror(errno))) }
                    offset += count
                }
            }
            guard fsync(fd) == 0 else { throw NVNVError.fileOperation(path: destination.lastPathComponent, reason: String(cString: strerror(errno))) }
            close(fd)
            Failpoint.trigger("after-temporary-flush")

            if FileManager.default.fileExists(atPath: destination.path) {
                let current = try Data(contentsOf: destination)
                let currentHash = Hashing.sha256(current)
                if let expectedHash, currentHash != expectedHash {
                    try? FileManager.default.removeItem(at: temporary)
                    return .conflict(currentData: current, currentHash: currentHash)
                }
            } else if expectedHash != nil {
                try? FileManager.default.removeItem(at: temporary)
                return .conflict(currentData: Data(), currentHash: "")
            }

            Failpoint.trigger("after-destination-comparison")

            if FileManager.default.fileExists(atPath: destination.path) {
                try preserveMetadata(from: destination, to: temporary)
            }

            guard Darwin.rename(temporary.path, destination.path) == 0 else {
                throw NVNVError.fileOperation(path: destination.lastPathComponent, reason: String(cString: strerror(errno)))
            }
            Failpoint.trigger("after-atomic-replacement")
            try syncDirectory()
            Failpoint.trigger("after-directory-durability")
            let verified = try Data(contentsOf: destination)
            guard verified == bytes else { throw NVNVError.fileOperation(path: destination.lastPathComponent, reason: "verification failed") }
            return .saved(try writeMetadata(for: destination, hash: Hashing.sha256(verified)))
        } catch {
            close(fd)
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    private func syncDirectory() throws {
        let fd = open(libraryURL.path, O_RDONLY)
        guard fd >= 0 else { throw NVNVError.fileOperation(path: libraryURL.path, reason: String(cString: strerror(errno))) }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw NVNVError.fileOperation(path: libraryURL.path, reason: String(cString: strerror(errno))) }
    }

    private func preserveMetadata(from source: URL, to destination: URL) throws {
        let sourceValues = try source.resourceValues(forKeys: [.creationDateKey])
        let flags = copyfile_flags_t(COPYFILE_METADATA | COPYFILE_NOFOLLOW)
        guard copyfile(source.path, destination.path, nil, flags) == 0 else {
            throw NVNVError.fileOperation(
                path: source.lastPathComponent,
                reason: "could not preserve file metadata: \(String(cString: strerror(errno)))"
            )
        }

        var values = URLResourceValues()
        values.creationDate = sourceValues.creationDate
        values.contentModificationDate = .now
        var mutableDestination = destination
        try mutableDestination.setResourceValues(values)

        let descriptor = open(destination.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw NVNVError.fileOperation(path: source.lastPathComponent, reason: String(cString: strerror(errno)))
        }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw NVNVError.fileOperation(path: source.lastPathComponent, reason: String(cString: strerror(errno)))
        }
    }

    private func writeMetadata(for url: URL, hash: String) throws -> FileWriteMetadata {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            throw NVNVError.fileOperation(path: url.lastPathComponent, reason: String(cString: strerror(errno)))
        }
        return FileWriteMetadata(
            hash: hash,
            modifiedAt: Date(
                timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)
                    + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000
            ),
            identity: "\(info.st_dev):\(info.st_ino)",
            fileSize: Int64(info.st_size),
            modificationSeconds: Int64(info.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(info.st_mtimespec.tv_nsec),
            statusChangeSeconds: Int64(info.st_ctimespec.tv_sec),
            statusChangeNanoseconds: Int64(info.st_ctimespec.tv_nsec)
        )
    }
}
