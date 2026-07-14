import NVNVCore
import SwiftUI

struct EditorPane: View {
    @Bindable var model: AppModel
    let undoRegistry: EditorUndoRegistry

    var body: some View {
        Group {
            if model.isRestoringLibrary {
                Color.clear
            } else if model.selection.isEmpty {
                EmptyEditorMessage("No Note Selected")
            } else if model.selection.count > 1 {
                EmptyEditorMessage("\(model.selection.count) Notes Selected")
            } else if let note = model.selectedNote {
                PlainTextEditor(
                    note: note,
                    editable: !model.isReadOnly && model.conflict?.noteID != note.id,
                    matchRanges: model.highlightSearch ? (model.selectedResult?.bodyRanges ?? []) : [],
                    fontName: model.editorFontName,
                    fontSize: model.editorFontSize,
                    softTabs: model.softTabs,
                    tabWidth: model.tabWidth,
                    tabIndents: model.tabIndents,
                    focusRequest: model.editorFocusRequest,
                    command: model.editorCommand,
                    commandGeneration: model.editorCommandGeneration,
                    undoInvalidationGeneration: model.undoInvalidationGenerations[note.id, default: 0],
                    undoRegistry: undoRegistry,
                    onChange: model.updateBody,
                    onSelectionChange: model.updateSelection,
                    onEditingEnded: model.finishEditingBurst,
                    onFocusRequestHandled: model.consumeEditorFocusRequest
                )
                .id(note.id)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct EmptyEditorMessage: View {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var body: some View {
        Text(message)
            .font(.system(size: 17, weight: .regular))
            .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
