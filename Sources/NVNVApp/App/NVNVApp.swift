import SwiftUI

@main
struct NVNVApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Library windows are created by AppKit after their saved frames load.
        // A WindowGroup would show an automatically positioned startup window.
        Settings {
            LibrarySettingsHost(coordinator: appDelegate.coordinator)
        }
        .commands { NVNVCommands(coordinator: appDelegate.coordinator) }
    }
}
