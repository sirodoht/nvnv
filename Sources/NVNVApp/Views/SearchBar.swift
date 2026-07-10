import SwiftUI

struct SearchBar: View {
    @Bindable var model: AppModel
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: model.isRenaming ? "pencil" : "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(model.isRenaming ? "Rename Note" : "Search notes or enter a new title", text: $model.searchText)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit { Task { await model.submitSearch() } }
                .onKeyPress(.upArrow) { model.moveSelection(by: -1); return .handled }
                .onKeyPress(.downArrow) { model.moveSelection(by: 1); return .handled }
                .onKeyPress(.escape) { model.clearOrCancel(); return .handled }
            if !model.searchText.isEmpty {
                Button { model.clearOrCancel() } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(model.isRenaming ? "Cancel Rename" : "Clear Search")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
        .padding([.horizontal, .top], 10)
        .onChange(of: model.focusSearchGeneration) { _, _ in focused = true }
        .onAppear { focused = true }
    }
}
