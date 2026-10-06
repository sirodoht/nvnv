import AppKit
import SwiftUI

struct LibraryWindowHost: View {
    @Binding var libraryID: UUID?
    let coordinator: LibraryWindowCoordinator
    @Environment(\.openWindow) private var openWindow
    @State private var model: AppModel?

    var body: some View {
        Group {
            if let model {
                ContentView(model: model)
                    .focusedSceneValue(model)
                    .navigationTitle(model.activeLibrary?.name ?? "nvnv")
                    .background(LibraryWindowAttachment(model: model, coordinator: coordinator))
                    .onChange(of: model.activeLibrary?.id) { _, id in libraryID = id }
            } else {
                ProgressView("Opening libraries…")
                    .frame(minWidth: 440, minHeight: 560)
            }
        }
        .task {
            guard model == nil else { return }
            let openAction = openWindow
            coordinator.presentWindow = { id in
                if let id { openAction(id: "library", value: id) }
                else { openAction(id: "library") }
            }
            let session = coordinator.makeModel(for: libraryID)
            model = session
            if let libraryID, session.libraryURL == nil,
               let library = coordinator.catalogStore.catalog.libraries.first(where: { $0.id == libraryID }) {
                await coordinator.open(library.url, from: session, inNewWindow: false)
            }
            await coordinator.restoreWorkspace(into: session)
            libraryID = session.activeLibrary?.id
        }
    }
}

private struct LibraryWindowAttachment: NSViewRepresentable {
    let model: AppModel
    let coordinator: LibraryWindowCoordinator

    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ view: NSView, context: Context) {
        // Register after SwiftUI has attached the view to its window. Observe the
        // session here too, so switching libraries reapplies that library's frame.
        _ = model.librarySessionID
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            coordinator.attach(window, to: model)
        }
    }
}

struct LibrarySettingsHost: View {
    @Bindable var coordinator: LibraryWindowCoordinator

    var body: some View {
        if let model = coordinator.settingsModel, model.libraryURL != nil {
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
