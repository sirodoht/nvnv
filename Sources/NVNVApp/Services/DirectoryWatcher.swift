import Darwin
import Foundation

final class DirectoryWatcher: @unchecked Sendable {
    private let descriptor: Int32
    private let source: DispatchSourceFileSystemObject
    private let callback: @Sendable () -> Void
    private var pending: DispatchWorkItem?

    init?(url: URL, callback: @escaping @Sendable () -> Void) {
        descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        self.callback = callback
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .extend, .attrib, .link, .revoke],
            queue: DispatchQueue(label: "app.nvnv.library-watcher")
        )
        source.setEventHandler { [weak self] in self?.debounce() }
        source.setCancelHandler { [descriptor] in close(descriptor) }
        source.resume()
    }

    deinit { source.cancel() }

    private func debounce() {
        pending?.cancel()
        let callback = callback
        let item = DispatchWorkItem { callback() }
        pending = item
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(250), execute: item)
    }
}
