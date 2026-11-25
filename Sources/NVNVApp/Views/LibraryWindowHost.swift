import SwiftUI

struct LibrarySettingsHost: View {
    @Bindable var coordinator: LibraryWindowCoordinator

    var body: some View {
        if let model = coordinator.settingsModel, model.libraryURL != nil || coordinator.isChangingSettingsLibrary {
            VStack(spacing: 0) {
                Text("Settings for \(model.activeLibrary?.name ?? "Library")")
                    .font(.headline).padding(.top, 16)
                SettingsView(model: model)
            }
        } else {
            ContentUnavailableView("No Library Selected", systemImage: "books.vertical",
                                   description: Text("Open Settings from a library window."))
                .frame(width: 560, height: 300)
        }
    }
}
