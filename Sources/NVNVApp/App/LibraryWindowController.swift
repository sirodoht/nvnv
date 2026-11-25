import AppKit
import NVNVCore

/// Owns a library's native window and restores its frame before presentation.
@MainActor
final class LibraryWindowController: NSObject, NSWindowDelegate {
    let window: NSWindow?
    private let model: AppModel
    private weak var coordinator: LibraryWindowCoordinator?
    // NSObject's delegate introspection is nonisolated. This reference is
    // immutable; actual lifecycle messages are delivered on the main actor.
    nonisolated(unsafe) private let originalDelegate: (any NSWindowDelegate)?
    private var appliedSessionID: UUID?
    private var allowingClose = false
    private var isClosing = false
    private var changingFullScreen = false
    private var applyingLayout = false
    private var pendingNormalFrame: LibraryWindowFrame?

    init(window: NSWindow, model: AppModel, coordinator: LibraryWindowCoordinator) {
        self.window = window
        self.model = model
        self.coordinator = coordinator
        originalDelegate = window.delegate
        super.init()
        window.delegate = self
    }

    override nonisolated func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || originalDelegate?.responds(to: selector) == true
    }

    override nonisolated func forwardingTarget(for selector: Selector!) -> Any? {
        if originalDelegate?.responds(to: selector) == true { return originalDelegate }
        return super.forwardingTarget(for: selector)
    }

    func synchronize() {
        guard let window else { return }
        window.title = model.activeLibrary?.name ?? "nvnv"
        guard model.libraryURL != nil, !model.isSwitchingLibrary,
              appliedSessionID != model.librarySessionID else { return }
        appliedSessionID = model.librarySessionID
        if window.styleMask.contains(.fullScreen) {
            pendingNormalFrame = model.windowFrame
        } else {
            applyFrame(model.windowFrame, to: window)
        }
        if window.isVisible, window.styleMask.contains(.fullScreen) != model.windowIsFullScreen {
            window.toggleFullScreen(nil)
        }
        recordFrame()
        if window.isKeyWindow { coordinator?.focused(model) }
    }

    func present() {
        guard let window else { return }
        synchronize()
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        if !changingFullScreen, window.styleMask.contains(.fullScreen) != model.windowIsFullScreen {
            window.toggleFullScreen(nil)
        }
    }

    private func applyFrame(_ stored: LibraryWindowFrame?, to window: NSWindow) {
        guard let stored, stored.width.isFinite, stored.height.isFinite,
              stored.x.isFinite, stored.y.isFinite, stored.width >= 440, stored.height >= 560 else { return }
        var frame = NSRect(x: stored.x, y: stored.y, width: stored.width, height: stored.height)
        if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }),
           let screen = window.screen ?? NSScreen.main {
            frame.origin = NSPoint(x: screen.visibleFrame.midX - frame.width / 2,
                                   y: screen.visibleFrame.midY - frame.height / 2)
        }
        applyingLayout = true
        window.setFrame(frame, display: true)
        applyingLayout = false
    }

    func recordFrame() {
        guard !applyingLayout, !changingFullScreen, !model.isSwitchingLibrary,
              appliedSessionID == model.librarySessionID,
              model.libraryURL != nil, let window, !window.styleMask.contains(.fullScreen) else { return }
        let frame = window.frame
        let value = LibraryWindowFrame(x: frame.origin.x, y: frame.origin.y,
                                       width: frame.width, height: frame.height)
        if model.windowFrame != value { model.windowFrame = value }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if allowingClose { return originalDelegate?.windowShouldClose?(sender) ?? true }
        guard !isClosing, coordinator?.isQuitting != true else { return false }
        isClosing = true
        recordFrame()
        Task {
            do {
                try await model.prepareForWindowClose()
                allowingClose = true
                sender.performClose(nil)
                // Another delegate can veto close; leave that window editable.
                if coordinator?.models.contains(where: { $0 === model }) == true {
                    allowingClose = false
                    isClosing = false
                    model.cancelWindowClose()
                }
            } catch {
                isClosing = false
                model.errorMessage = error.localizedDescription
                sender.makeKeyAndOrderFront(nil)
            }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        originalDelegate?.windowWillClose?(notification)
        coordinator?.didClose(model)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        originalDelegate?.windowDidBecomeKey?(notification)
        coordinator?.focused(model)
    }

    func windowDidResignKey(_ notification: Notification) {
        originalDelegate?.windowDidResignKey?(notification)
        coordinator?.unfocused(model)
        if !model.isSwitchingLibrary { Task { try? await model.flushAll() } }
    }

    func windowDidResize(_ notification: Notification) {
        originalDelegate?.windowDidResize?(notification)
        recordFrame()
    }

    func windowDidMove(_ notification: Notification) {
        originalDelegate?.windowDidMove?(notification)
        recordFrame()
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        recordFrame()
        changingFullScreen = true
        originalDelegate?.windowWillEnterFullScreen?(notification)
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        changingFullScreen = false
        model.windowIsFullScreen = true
        originalDelegate?.windowDidEnterFullScreen?(notification)
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        changingFullScreen = true
        originalDelegate?.windowWillExitFullScreen?(notification)
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        changingFullScreen = false
        model.windowIsFullScreen = false
        if let window, let frame = pendingNormalFrame {
            pendingNormalFrame = nil
            applyFrame(frame, to: window)
        }
        recordFrame()
        originalDelegate?.windowDidExitFullScreen?(notification)
    }
}
