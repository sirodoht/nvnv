import SwiftUI

@main
struct NVNVApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var coordinator = LibraryWindowCoordinator()

    var body: some Scene {
        WindowGroup("nvnv", id: "library", for: UUID.self) { $libraryID in
            LibraryWindowHost(libraryID: $libraryID, coordinator: coordinator)
                .onAppear { appDelegate.coordinator = coordinator }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 480, height: 860)
        // The workspace restores every open library, independent of the OS's
        // optional restoration. Avoid also restoring duplicate SwiftUI scenes.
        .restorationBehavior(.disabled)
        .commands { NVNVCommands(coordinator: coordinator) }

        Settings { LibrarySettingsHost(coordinator: coordinator) }
    }
}
