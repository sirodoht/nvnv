import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let coordinator = LibraryWindowCoordinator()
    private var didRestoreWorkspace = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        coordinator.makeWindow = { model in
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 860),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.isRestorable = false
            window.animationBehavior = .none
            window.tabbingMode = .disallowed
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.contentMinSize = NSSize(width: 440, height: 560)
            window.contentView = NSHostingView(rootView: ContentView(model: model)
                .onChange(of: model.activeLibrary?.name) { _, _ in
                    model.windowCoordinator?.synchronizeWindow(for: model)
                })
            window.contentView?.layoutSubtreeIfNeeded()
            if model.windowFrame == nil { window.center() }
            return window
        }
        Task {
            let initial = coordinator.makeModel()
            await coordinator.restoreWorkspace(into: initial)
            coordinator.show(initial)
            didRestoreWorkspace = true
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard didRestoreWorkspace, !coordinator.isQuitting else { return false }
        if !flag {
            if coordinator.models.isEmpty { coordinator.newWindow() }
            else { for model in coordinator.models { coordinator.show(model) } }
        }
        return false
    }

    func applicationDidUpdate(_ notification: Notification) {
        for window in NSApp.windows {
            configureScrollers(in: window.contentView)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !coordinator.isQuitting else { return .terminateLater }
        Task {
            do {
                try await coordinator.prepareForQuit()
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
