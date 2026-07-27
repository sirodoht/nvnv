import SwiftUI

struct NVNVCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(model.libraryURL == nil ? "Open Notes Folder…" : "Choose Another Notes Folder…") {
                Task { await model.chooseLibrary() }
            }
                .keyboardShortcut("o")
            if model.libraryURL != nil {
                Divider()
                Button("Forget Library…") { Task { await model.confirmAndForgetLibrary() } }
            }
        }
        CommandMenu("Note") {
            Button("Focus Search") { model.focusSearch() }.keyboardShortcut("l")
            Button("Next Note") { model.moveSelection(by: 1) }.keyboardShortcut("j")
            Button("Previous Note") { model.moveSelection(by: -1) }.keyboardShortcut("k")
            Button("Deselect Note") { model.deselect() }.keyboardShortcut("d")
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
    }
}
