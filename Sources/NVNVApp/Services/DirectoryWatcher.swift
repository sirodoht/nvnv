import Foundation

final class DirectoryWatcher: @unchecked Sendable {
    struct Change: Sendable {
        let paths: Set<URL>
        let requiresFullRescan: Bool
    }

    private let rootURL: URL
    private let queue = DispatchQueue(label: "app.nvnv.library-watcher", qos: .utility)
    private let callbackBox: DirectoryWatcherCallbackBox
    private var stream: FSEventStreamRef?
    private var pendingPaths: Set<URL> = []
    private var pendingRequiresFullRescan = false
    private var pendingDelivery: DispatchWorkItem?

    init?(url: URL, callback: @escaping @Sendable (Change) -> Void) {
        rootURL = url.standardizedFileURL
        callbackBox = DirectoryWatcherCallbackBox(callback: callback)

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(callbackBox).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let paths = [rootURL.path] as CFArray
        guard let stream = FSEventStreamCreate(
            nil,
            directoryWatcherCallback,
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.05,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        ) else { return nil }

        callbackBox.watcher = self
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return nil
        }
        self.stream = stream
    }

    deinit {
        pendingDelivery?.cancel()
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    fileprivate func receive(paths: [String], flags: [FSEventStreamEventFlags]) {
        if paths.isEmpty || paths.count != flags.count {
            pendingRequiresFullRescan = true
        }
        for (path, flags) in zip(paths, flags) {
            if flagsRequireFullRescan(flags) {
                pendingRequiresFullRescan = true
                continue
            }
            if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone) != 0 { continue }
            // File-event streams can include metadata events for directories in
            // addition to the exact child paths. The app only indexes files;
            // dropped/coalesced events are covered by the rescan flags above.
            if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0 { continue }
            pendingPaths.insert(URL(fileURLWithPath: path).standardizedFileURL)
        }
        guard pendingRequiresFullRescan || !pendingPaths.isEmpty else { return }
        scheduleDelivery()
    }

    private func flagsRequireFullRescan(_ flags: FSEventStreamEventFlags) -> Bool {
        let mask = FSEventStreamEventFlags(
            kFSEventStreamEventFlagMustScanSubDirs
                | kFSEventStreamEventFlagKernelDropped
                | kFSEventStreamEventFlagUserDropped
                | kFSEventStreamEventFlagEventIdsWrapped
                | kFSEventStreamEventFlagRootChanged
                | kFSEventStreamEventFlagMount
                | kFSEventStreamEventFlagUnmount
                // FSEvents can report only one side of a rename. A full scan is
                // required to discover the authoritative old/new path pair.
                | kFSEventStreamEventFlagItemRenamed
        )
        return flags & mask != 0
    }

    private func scheduleDelivery() {
        pendingDelivery?.cancel()
        let delivery = DispatchWorkItem { [weak self] in self?.deliverPendingChange() }
        pendingDelivery = delivery
        queue.asyncAfter(deadline: .now() + .milliseconds(250), execute: delivery)
    }

    private func deliverPendingChange() {
        let change = Change(
            paths: pendingPaths,
            requiresFullRescan: pendingRequiresFullRescan || pendingPaths.isEmpty
        )
        pendingPaths.removeAll(keepingCapacity: true)
        pendingRequiresFullRescan = false
        pendingDelivery = nil
        callbackBox.callback(change)
    }
}

/// Collects events while the initial authoritative scan is in progress. Any
/// startup event becomes one full rescan, which closes the `sinceNow` gap
/// without trying to replay an order-sensitive partial event sequence.
final class DirectoryWatcherStartupBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var sawChange = false
    private var handler: (@Sendable (DirectoryWatcher.Change) -> Void)?

    func receive(_ change: DirectoryWatcher.Change) {
        lock.lock()
        if let handler {
            lock.unlock()
            handler(change)
        } else {
            sawChange = true
            lock.unlock()
        }
    }

    func activate(_ handler: @escaping @Sendable (DirectoryWatcher.Change) -> Void) {
        lock.lock()
        if sawChange {
            // Invoke while holding the lock so later watcher events cannot be
            // delivered ahead of this startup reconciliation request.
            handler(.init(paths: [], requiresFullRescan: true))
            sawChange = false
        }
        self.handler = handler
        lock.unlock()
    }
}

private final class DirectoryWatcherCallbackBox: @unchecked Sendable {
    let callback: @Sendable (DirectoryWatcher.Change) -> Void
    weak var watcher: DirectoryWatcher?

    init(callback: @escaping @Sendable (DirectoryWatcher.Change) -> Void) {
        self.callback = callback
    }
}

private func directoryWatcherCallback(
    _ stream: ConstFSEventStreamRef,
    _ context: UnsafeMutableRawPointer?,
    _ eventCount: Int,
    _ eventPaths: UnsafeMutableRawPointer,
    _ eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    _ eventIDs: UnsafePointer<FSEventStreamEventId>
) {
    guard let context else { return }
    let watcher = Unmanaged<DirectoryWatcherCallbackBox>.fromOpaque(context).takeUnretainedValue()
    let pathArray = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as NSArray
    let paths = (pathArray as? [String]) ?? []
    let flags = (0..<eventCount).map { eventFlags[$0] }
    watcher.watcher?.receive(paths: paths, flags: flags)
}
