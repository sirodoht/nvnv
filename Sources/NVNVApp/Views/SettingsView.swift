import AppKit
import NVNVCore
import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var fontPanelController = EditorFontPanelController()
    @State private var isForgetConfirmationPresented = false
    @State private var isResetConfirmationPresented = false
    @State private var isRenameConfirmationPresented = false
    @State private var libraryName = ""
    @State private var isSwitcherPresented = false
    @State private var managedLibrary: NamedLibrary?

    var body: some View {
        Form {
            Section("Library") {
                if let libraryURL = model.libraryURL {
                    LabeledContent("Name") {
                        Text(model.activeLibrary?.name ?? libraryURL.lastPathComponent)
                        Button("Rename…") {
                            managedLibrary = model.activeLibrary
                            libraryName = model.activeLibrary?.name ?? ""
                            isRenameConfirmationPresented = true
                        }
                    }
                    LabeledContent("Notes folder") {
                        Text(libraryURL.path)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(libraryURL.path)
                    }
                    HStack {
                        Button("Switch Library…") { isSwitcherPresented = true }
                        Button("Add Library…") { changeLibrary { await model.chooseLibrary() } }
                        Spacer()
                        Button("Remove from List…") {
                            managedLibrary = model.activeLibrary
                            isForgetConfirmationPresented = true
                        }
                    }
                } else {
                    Button("Add Library…") { changeLibrary { await model.chooseLibrary() } }
                    if !model.libraries.isEmpty {
                        Button("Switch Library…") { isSwitcherPresented = true }
                    }
                }
            }
            Section("Note List") {
                Toggle("Show body excerpts", isOn: $model.showExcerpts)
            }
            Section("Editor") {
                HStack {
                    Text("Font")
                    Spacer()
                    Text(editorFontDisplayName)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Button("Choose…") { fontPanelController.show(for: model) }
                    Button("Default") {
                        model.editorFontName = ""
                        model.editorFontSize = 12
                    }
                }
                HStack { Text("Text size"); Slider(value: $model.editorFontSize, in: 10...14, step: 1); Text("\(Int(model.editorFontSize)) pt").monospacedDigit() }
                Toggle("Use spaces for indentation", isOn: $model.softTabs)
                Toggle("Tab indents text", isOn: $model.tabIndents)
                Stepper("Tab width: \(model.tabWidth)", value: $model.tabWidth, in: 1...16)
                Toggle("Highlight search matches", isOn: $model.highlightSearch)
            }
            Section("Safety") { Toggle("Confirm before moving notes to Trash", isOn: $model.confirmDeletion) }
            Section("Files") {
                TextField("Recognized extensions (comma-separated)", text: $model.extensionList)
                TextField("Default extension", text: $model.defaultExtension)
                Text("The default extension is always recognized. Changes take effect on the next filesystem reconciliation.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("Reset Settings…", role: .destructive) {
                    isResetConfirmationPresented = true
                }
                .disabled(model.libraryURL == nil || model.isReadOnly)
            } footer: {
                Text("Restores settings for this library. Note files are never changed.")
            }
        }
        .formStyle(.grouped)
        .disabled(model.isSwitchingLibrary)
        .padding().frame(width: 560, height: 650)
        .onDisappear { fontPanelController.stop() }
        .sheet(isPresented: $isSwitcherPresented, onDismiss: finishLibrarySwitcher) {
            LibrarySwitcher(model: model)
        }
        .alert("Rename Library", isPresented: $isRenameConfirmationPresented) {
            TextField("Library name", text: $libraryName)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                if let library = managedLibrary { model.renameLibrary(library, to: libraryName) }
            }
            .disabled(libraryName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("The library’s folder name will stay the same.")
        }
        .alert("Remove Library from List?", isPresented: $isForgetConfirmationPresented) {
            Button("Cancel", role: .cancel) {}
            Button("Remove from List") {
                if let library = managedLibrary { Task { await model.removeLibrary(library) } }
            }
        } message: {
            Text("Remove “\(managedLibrary?.name ?? "")” from nvnv’s library list? All notes and the folder’s .nvnv data will remain on disk.")
        }
        .alert("Reset library settings?", isPresented: $isResetConfirmationPresented) {
            Button("Cancel", role: .cancel) {}
            Button("Reset Settings", role: .destructive) { Task { await model.resetSettings() } }
        } message: {
            Text("Display, editor, safety, and file preferences for this library will return to their defaults. Note files will remain untouched.")
        }
    }

    private func finishLibrarySwitcher() {
        switch model.librarySwitcherAction {
        case .rename(let library):
            model.librarySwitcherAction = nil
            managedLibrary = library
            libraryName = library.name
            isRenameConfirmationPresented = true
        case .remove(let library):
            model.librarySwitcherAction = nil
            managedLibrary = library
            isForgetConfirmationPresented = true
        case .open(let library):
            model.librarySwitcherAction = nil
            changeLibrary { await model.switchLibrary(to: library) }
        case .add:
            model.librarySwitcherAction = nil
            changeLibrary { await model.chooseLibrary() }
        default:
            model.finishLibrarySwitcher()
        }
    }

    /// Changes this window's library while keeping Settings attached to it.
    private func changeLibrary(_ change: @escaping @MainActor () async -> Void) {
        let model = model
        Task {
            if let coordinator = model.windowCoordinator {
                await coordinator.changeLibraryFromSettings(of: model, change)
            } else {
                await change()
            }
        }
    }

    private var editorFontDisplayName: String {
        let font = model.editorFontName.isEmpty
            ? NSFont.monospacedSystemFont(ofSize: model.editorFontSize, weight: .regular)
            : NSFont(name: model.editorFontName, size: model.editorFontSize)
        return font?.displayName ?? "System Monospace"
    }
}

@MainActor
private final class EditorFontPanelController: NSObject {
    private weak var model: AppModel?

    func show(for model: AppModel) {
        self.model = model
        let currentFont = resolvedFont(for: model)
        let manager = NSFontManager.shared
        manager.setSelectedFont(currentFont, isMultiple: false)
        manager.target = self
        manager.action = #selector(changeFont(_:))
        manager.orderFrontFontPanel(nil)
    }

    func stop() {
        let manager = NSFontManager.shared
        if manager.target === self { manager.target = nil }
        model = nil
    }

    @objc private func changeFont(_ sender: NSFontManager) {
        guard let model else { return }
        let converted = sender.convert(resolvedFont(for: model))
        model.editorFontName = converted.fontName
        model.editorFontSize = min(max(Double(converted.pointSize), 10), 14)
    }

    private func resolvedFont(for model: AppModel) -> NSFont {
        if !model.editorFontName.isEmpty,
           let chosen = NSFont(name: model.editorFontName, size: model.editorFontSize) {
            return chosen
        }
        return NSFont.monospacedSystemFont(ofSize: model.editorFontSize, weight: .regular)
    }
}
