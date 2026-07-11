import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationDidUpdate(_ notification: Notification) {
        for window in NSApp.windows {
            configureScrollers(in: window.contentView)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        Task {
            do {
                try await model.flushAll()
                sender.reply(toApplicationShouldTerminate: true)
            } catch {
                let alert = NSAlert(error: error)
                alert.informativeText = "Some changes may still be pending. Retry after resolving the error, or force quit to rely on recovery data."
                alert.runModal()
                sender.reply(toApplicationShouldTerminate: false)
            }
        }
        return .terminateLater
    }

    private func configureScrollers(in view: NSView?) {
        guard let view else { return }
        if let scrollView = view as? NSScrollView {
            if let verticalScroller = scrollView.verticalScroller,
               verticalScroller.controlSize != .small {
                verticalScroller.controlSize = .small
            }
            if let horizontalScroller = scrollView.horizontalScroller,
               horizontalScroller.controlSize != .small {
                horizontalScroller.controlSize = .small
            }
        }
        for subview in view.subviews {
            configureScrollers(in: subview)
        }
    }
}
