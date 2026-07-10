import NVNVCore
import SwiftUI

struct NoteListView: View {
    @Bindable var model: AppModel

    var body: some View {
        List(selection: Binding(
            get: { model.selection },
            set: { model.select($0) }
        )) {
            ForEach(model.results) { result in
                NoteRow(
                    note: result.note,
                    showExcerpt: model.showExcerpts,
                    showModified: model.showModifiedDate,
                    showCreated: model.showCreatedDate,
                    duplicateTitle: duplicateTitles.contains(TextNormalizer.normalize(result.note.title)),
                    fontSize: model.listFontSize
                )
                .tag(result.id)
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
    }

    private var duplicateTitles: Set<String> {
        let grouped = Dictionary(grouping: model.notes, by: { TextNormalizer.normalize($0.title) })
        return Set(grouped.filter { $0.value.count > 1 }.map(\.key))
    }
}

private struct NoteRow: View {
    let note: Note
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
                    Text(note.createdAt, style: .relative).font(.caption).foregroundStyle(.secondary)
                }
            }
            if showModified {
                VStack(alignment: .trailing, spacing: 1) {
                    Text("Modified").font(.caption2).foregroundStyle(.tertiary)
                    Text(note.modifiedAt, style: .relative).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, showExcerpt ? 4 : 1)
    }

    private var excerpt: String {
        note.body.split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
    }
}
