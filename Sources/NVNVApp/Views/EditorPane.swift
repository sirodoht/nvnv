import NVNVCore
import SwiftUI

struct EditorPane: View {
    @Bindable var model: AppModel
    let undoRegistry: EditorUndoRegistry

    var body: some View {
        Group {
            if model.selection.isEmpty {
                ContentUnavailableView("No Note Selected", systemImage: "note.text")
            } else if model.selection.count > 1 {
                ContentUnavailableView("\(model.selection.count) Notes Selected", systemImage: "square.stack.3d.up")
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
                    undoRegistry: undoRegistry,
                    onChange: model.updateBody,
                    onSelectionChange: model.updateSelection,
                    onFocusRequestHandled: model.consumeEditorFocusRequest
                )
                .id(note.id)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
