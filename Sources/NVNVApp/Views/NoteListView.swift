import NVNVCore
import SwiftUI

struct NoteListView: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollViewReader { proxy in
            List(selection: Binding(
                get: { nativeSelection },
                set: { ids in
                    guard ids != nativeSelection else { return }
                    model.select(ids)
                }
            )) {
                ForEach(model.results) { result in
                    NoteRow(
                        note: result.note,
                        excerpt: result.excerpt,
                        showExcerpt: model.showExcerpts,
                        showModified: model.showModifiedDate,
                        showCreated: model.showCreatedDate,
                        duplicateTitle: model.duplicateTitleKeys.contains(TextNormalizer.normalize(result.note.title)),
                        fontSize: model.listFontSize
                    )
                    .id(result.id)
                    .tag(result.id)
                    .listRowBackground(
                        model.selectionKind == .automatic && model.selection.contains(result.id)
                            ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.28)
                            : Color.clear
                    )
                    .contextMenu {
                        Button("Rename") { model.startRename() }
                            .disabled(model.isReadOnly)
                        Button("Show in Finder") { model.revealSelectedNote() }
                        Divider()
                        Button("Move to Trash", role: .destructive) { Task { await model.deleteSelection() } }
                            .disabled(model.isReadOnly)
                    }
                }
            }
            .listStyle(.inset)
            .overlay {
                if model.results.isEmpty {
                    ContentUnavailableView(
                        model.query.isEmpty ? "No Notes" : "No Matches",
                        systemImage: model.query.isEmpty ? "note.text" : "magnifyingglass",
                        description: Text(model.query.isEmpty ? "Type a title above and press Return to create a note." : "Press Return to create “\(model.query)” as a note.")
                    )
                }
            }
            .onChange(of: model.listScrollRequest) { _, _ in
                fulfillScrollRequest(using: proxy)
            }
            .onChange(of: model.results.map(\.id)) { _, _ in
                fulfillScrollRequest(using: proxy)
            }
        }
    }

    private var nativeSelection: Set<UUID> {
        model.selectionKind == .explicit ? model.selection : []
    }

    private func fulfillScrollRequest(using proxy: ScrollViewProxy) {
        guard let request = model.listScrollRequest,
              model.results.contains(where: { $0.id == request.noteID }) else { return }
        DispatchQueue.main.async {
            proxy.scrollTo(request.noteID, anchor: .top)
            model.consumeListScrollRequest(request.id)
        }
    }
}

private struct NoteRow: View {
    let note: Note
    let excerpt: String
    let showExcerpt: Bool
    let showModified: Bool
    let showCreated: Bool
    let duplicateTitle: Bool
    let fontSize: Double

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(note.title).font(.system(size: fontSize, weight: .medium)).lineLimit(1)
                    if duplicateTitle {
                        Text(note.filename).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                if showExcerpt, !excerpt.isEmpty {
                    Text(excerpt).font(.system(size: max(10, fontSize - 1))).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 10)
            if showCreated {
                VStack(alignment: .trailing, spacing: 1) {
                    Text("Created").font(.caption2).foregroundStyle(.tertiary)
                    Text(note.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                }
            }
            if showModified {
                VStack(alignment: .trailing, spacing: 1) {
                    Text("Modified").font(.caption2).foregroundStyle(.tertiary)
                    Text(note.modifiedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, showExcerpt ? 4 : 1)
    }
}
