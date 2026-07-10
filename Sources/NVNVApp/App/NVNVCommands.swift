import SwiftUI

struct NVNVCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open Notes Folder…") { Task { await model.chooseLibrary() } }
                .keyboardShortcut("o")
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
                .keyboardShortcut(.delete, modifiers: .command)
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
            Button("Open URL at Cursor") { model.performEditorCommand(.openURL) }
            if model.conflict != nil {
                Button("Resolve Conflict…") { model.showConflictResolver() }
            }
        }
    }
}
