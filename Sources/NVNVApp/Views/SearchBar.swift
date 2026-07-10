import SwiftUI

struct SearchBar: View {
    @Bindable var model: AppModel
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: model.isRenaming ? "pencil" : "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField(
                model.isRenaming ? "Rename Note" : "Search notes or enter a new title",
                text: Binding(
                    get: { model.searchText },
                    set: { model.userEnteredSearchText($0) }
                )
            )
                .textFieldStyle(.plain)
                .font(.system(size: 12))
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
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .help(model.isRenaming ? "Cancel Rename" : "Clear Search")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(.background, in: RoundedRectangle(cornerRadius: 5))
        .overlay {
            RoundedRectangle(cornerRadius: 5)
                .stroke(
                    focused ? Color.accentColor : Color.secondary.opacity(0.28),
                    lineWidth: focused ? 2 : 1
                )
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .onChange(of: model.focusSearchGeneration) { _, _ in focused = true }
        .onAppear { focused = true }
    }
}
