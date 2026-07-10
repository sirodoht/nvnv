import Darwin
import Foundation

public final class LibraryLock: @unchecked Sendable {
    private var descriptor: Int32 = -1
    public let isWritable: Bool

    public init(auxiliaryDirectory: URL) throws {
        try FileManager.default.createDirectory(at: auxiliaryDirectory, withIntermediateDirectories: true)
        let path = auxiliaryDirectory.appendingPathComponent("library.lock").path
        descriptor = open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw NVNVError.fileOperation(path: path, reason: String(cString: strerror(errno))) }
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
            isWritable = true
            let metadata = "pid=\(getpid()) acquired=\(ISO8601DateFormatter().string(from: .now))\n"
            _ = ftruncate(descriptor, 0)
            metadata.withCString { pointer in _ = write(descriptor, pointer, strlen(pointer)) }
            _ = fsync(descriptor)
        } else {
            isWritable = false
        }
    }

    deinit {
        if descriptor >= 0 {
            if isWritable { _ = flock(descriptor, LOCK_UN) }
            _ = close(descriptor)
        }
    }
}
