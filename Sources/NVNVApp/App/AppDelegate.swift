import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
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
}
