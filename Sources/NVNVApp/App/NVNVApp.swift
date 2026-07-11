import SwiftUI

@main
struct NVNVApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("nvnv") {
            ContentView(model: model)
                .onAppear { appDelegate.model = model }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 920, height: 780)
        .commands { NVNVCommands(model: model) }

        Settings { SettingsView(model: model) }
    }
}
