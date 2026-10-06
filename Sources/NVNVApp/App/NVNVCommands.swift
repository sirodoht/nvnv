import SwiftUI

struct NVNVCommands: Commands {
    let coordinator: LibraryWindowCoordinator
    @FocusedValue(AppModel.self) private var focusedModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                coordinator.settingsLibraryID = focusedModel?.activeLibrary?.id
                openSettings()
            }
            .keyboardShortcut(",")
            .disabled(focusedModel?.libraryURL == nil || coordinator.isQuitting)
        }
        CommandGroup(replacing: .newItem) {
            Button("New Library Window…") { openWindow(id: "library") }
                .keyboardShortcut("n")
                .disabled(coordinator.isQuitting)
            if let model = focusedModel {
                Button("Add Library…") { Task { await model.chooseLibrary() } }
                    .keyboardShortcut("o")
                    .disabled(model.isSwitchingLibrary)
                Button("Switch Library…") { model.showLibrarySwitcher() }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                    .disabled(model.isSwitchingLibrary)
                if let library = model.activeLibrary {
                    Divider()
                    Button("Rename Library…") { model.beginRenamingLibrary(library) }
                        .disabled(model.isSwitchingLibrary)
                    Button("Remove Library from List…") { model.libraryToRemove = library }
                        .disabled(model.isSwitchingLibrary)
                }
            } else {
                Button("Open Library…") { openWindow(id: "library") }
                    .keyboardShortcut("o")
                    .disabled(coordinator.isQuitting)
            }
        }
        CommandMenu("Note") {
            if let model = focusedModel {
                Group {
                    Button("Focus Search") { model.focusSearch() }.keyboardShortcut("l")
                    Button("Next Note") { model.moveSelection(by: 1) }.keyboardShortcut("j")
                    Button("Previous Note") { model.moveSelection(by: -1) }.keyboardShortcut("k")
                    Button("Deselect Note") { model.returnToSearch() }.keyboardShortcut("d")
                    Divider()
                    Button("Rename Note") { model.startRename() }.keyboardShortcut("r")
                        .disabled(model.isReadOnly || model.selection.count != 1)
                    Button("Move to Trash") { Task { await model.deleteSelection() } }
                        .disabled(model.isReadOnly || model.selection.isEmpty)
                    Button("Show in Finder") { model.revealSelectedNote() }
                        .keyboardShortcut("r", modifiers: [.command, .shift])
                        .disabled(model.selection.count != 1)
                    Button("Back") { model.navigateBack() }
                        .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                    Divider()
                    Button("Outdent") { model.performEditorCommand(.outdent) }
                        .keyboardShortcut("[", modifiers: .command)
                    Button("Indent") { model.performEditorCommand(.indent) }
                        .keyboardShortcut("]", modifiers: .command)
                    Divider()
                    Button("Find…") { model.performEditorCommand(.find) }
                        .keyboardShortcut("f", modifiers: .command)
                        .disabled(model.selection.count != 1)
                    Button("Find Next") { model.performEditorCommand(.findNext) }
                        .keyboardShortcut("g", modifiers: .command)
                        .disabled(model.selection.count != 1)
                    Button("Find Previous") { model.performEditorCommand(.findPrevious) }
                        .keyboardShortcut("g", modifiers: [.command, .shift])
                        .disabled(model.selection.count != 1)
                    Divider()
                    Button("Open URL at Cursor") { model.performEditorCommand(.openURL) }
                    if model.conflict != nil {
                        Button("Resolve Conflict…") { model.showConflictResolver() }
                    }
                }
                .disabled(model.isSwitchingLibrary)
            }
        }
    }
}
