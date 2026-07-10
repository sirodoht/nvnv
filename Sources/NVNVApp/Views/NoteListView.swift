import NVNVCore
import SwiftUI

struct NoteListView: View {
    @Bindable var model: AppModel
    @Environment(\.locale) private var locale
    @Environment(\.calendar) private var calendar
    @Environment(\.timeZone) private var timeZone
    @AppStorage("noteListModifiedDateColumnWidth") private var storedModifiedColumnWidth = 150.0
    @State private var rowContentInsets: NoteTableContentInsets?
    @State private var columnDragStartWidth: CGFloat?

    private let columnSeparatorWidth: CGFloat = 9
    private let minimumTitleColumnWidth: CGFloat = 120
    private let minimumDateColumnWidth: CGFloat = 100

    var body: some View {
        GeometryReader { tableGeometry in
            let modifiedWidth = effectiveModifiedColumnWidth(tableWidth: tableGeometry.size.width)
            VStack(spacing: 0) {
                columnHeader(tableWidth: tableGeometry.size.width, modifiedWidth: modifiedWidth)
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
                                fontSize: model.listFontSize,
                                modifiedColumnWidth: modifiedWidth,
                                createdColumnWidth: createdColumnWidth,
                                columnSeparatorWidth: columnSeparatorWidth,
                                createdDateText: model.showCreatedDate ? presentationDate(result.note.createdAt) : nil,
                                modifiedDateText: model.showModifiedDate ? presentationDate(result.note.modifiedAt) : nil
                            )
                            .background {
                                if result.id == model.results.first?.id {
                                    rowBoundsSentinel(tableWidth: tableGeometry.size.width)
                                }
                            }
                            .id(result.id)
                            .tag(result.id)
                            .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
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
                    .listStyle(.plain)
                    .environment(\.defaultMinListRowHeight, 18)
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
            .coordinateSpace(name: "note-table")
            .onPreferenceChange(NoteTableContentInsetsPreferenceKey.self) { insets in
                if let insets { rowContentInsets = insets }
            }
        }
    }

    private var createdColumnWidth: CGFloat { 130 }

    private func rowBoundsSentinel(tableWidth: CGFloat) -> some View {
        GeometryReader { geometry in
            let bounds = geometry.frame(in: .named("note-table"))
            Color.clear.preference(key: NoteTableContentInsetsPreferenceKey.self, value: NoteTableContentInsets(
                leading: max(bounds.minX, 0),
                trailing: max(tableWidth - bounds.maxX, 0)
            ))
        }
    }

    private func presentationDate(_ date: Date) -> String {
        PresentationDateCache.shared.string(
            for: date,
            locale: locale,
            calendar: calendar,
            timeZone: timeZone
        )
    }

    private func effectiveModifiedColumnWidth(tableWidth: CGFloat) -> CGFloat {
        min(max(CGFloat(storedModifiedColumnWidth), minimumDateColumnWidth), maximumModifiedColumnWidth(tableWidth: tableWidth))
    }

    private func maximumModifiedColumnWidth(tableWidth: CGFloat) -> CGFloat {
        let fallbackContentWidth = max(tableWidth - 44, 1)
        let contentWidth = rowContentInsets.map { max(tableWidth - $0.leading - $0.trailing, 1) } ?? fallbackContentWidth
        let createdAllocation = model.showCreatedDate ? createdColumnWidth + columnSeparatorWidth : 0
        return max(
            minimumDateColumnWidth,
            contentWidth - createdAllocation - columnSeparatorWidth - minimumTitleColumnWidth
        )
    }

    private func columnHeader(tableWidth: CGFloat, modifiedWidth: CGFloat) -> some View {
        let leadingInset = rowContentInsets?.leading ?? 8
        let trailingInset = rowContentInsets?.trailing ?? 36
        return HStack(spacing: 0) {
            sortHeader("Title", field: .title)
                .frame(maxWidth: .infinity, alignment: .leading)
            if model.showCreatedDate {
                passiveColumnSeparator
                sortHeader("Date Created", field: .created)
                    .frame(width: createdColumnWidth, alignment: .leading)
            }
            if model.showModifiedDate {
                modifiedColumnResizeHandle(tableWidth: tableWidth, currentWidth: modifiedWidth)
                sortHeader("Date Modified", field: .modified)
                    .frame(width: modifiedWidth, alignment: .leading)
            }
        }
        .padding(.leading, leadingInset)
        .padding(.trailing, trailingInset)
        .frame(height: 27)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var passiveColumnSeparator: some View {
        Rectangle()
            .fill(.separator)
            .frame(width: 1)
            .frame(width: columnSeparatorWidth)
    }

    private func modifiedColumnResizeHandle(tableWidth: CGFloat, currentWidth: CGFloat) -> some View {
        Rectangle()
            .fill(.separator)
            .frame(width: 1)
            .frame(width: columnSeparatorWidth)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering { NSCursor.resizeLeftRight.push() }
                else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(coordinateSpace: .global)
                    .onChanged { value in
                        if columnDragStartWidth == nil { columnDragStartWidth = currentWidth }
                        let proposed = (columnDragStartWidth ?? currentWidth) - value.translation.width
                        storedModifiedColumnWidth = Double(min(
                            max(proposed, minimumDateColumnWidth),
                            maximumModifiedColumnWidth(tableWidth: tableWidth)
                        ))
                    }
                    .onEnded { _ in columnDragStartWidth = nil }
            )
            .help("Drag to resize the Title and Date Modified columns")
    }

    private func sortHeader(_ title: String, field: NoteSortField) -> some View {
        Button {
            let ascending = model.sort.field == field ? !model.sort.ascending : field == .title
            model.sort = NoteSort(field: field, ascending: ascending)
        } label: {
            HStack(spacing: 4) {
                Text(title)
                if model.sort.field == field {
                    Image(systemName: model.sort.ascending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 7, weight: .semibold))
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .font(.system(size: 11, weight: .regular))
        .padding(.horizontal, 4)
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
    let modifiedColumnWidth: CGFloat
    let createdColumnWidth: CGFloat
    let columnSeparatorWidth: CGFloat
    let createdDateText: String?
    let modifiedDateText: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            rowText
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipped()
            if showCreated, let createdDateText {
                Color.clear.frame(width: columnSeparatorWidth)
                Text(createdDateText)
                    .font(.system(size: max(10, fontSize - 1)))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 4)
                    .frame(width: createdColumnWidth, alignment: .leading)
            }
            if showModified, let modifiedDateText {
                Color.clear.frame(width: columnSeparatorWidth)
                Text(modifiedDateText)
                    .font(.system(size: max(10, fontSize - 1)))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 4)
                    .frame(width: modifiedColumnWidth, alignment: .leading)
            }
        }
        .frame(minHeight: 16)
    }

    private var rowText: Text {
        var text = Text(note.title)
            .font(.system(size: fontSize, weight: .regular))
        if duplicateTitle {
            text = text + Text("  \(note.filename)")
                .font(.system(size: max(9, fontSize - 2)))
                .foregroundStyle(.secondary)
        }
        if showExcerpt, !excerpt.isEmpty {
            text = text + Text("  — \(excerpt)")
                .font(.system(size: max(10, fontSize - 1)))
                .foregroundStyle(.secondary)
        }
        return text
    }
}

private struct NoteTableContentInsets: Equatable {
    let leading: CGFloat
    let trailing: CGFloat
}

private struct NoteTableContentInsetsPreferenceKey: PreferenceKey {
    static let defaultValue: NoteTableContentInsets? = nil

    static func reduce(value: inout NoteTableContentInsets?, nextValue: () -> NoteTableContentInsets?) {
        if let next = nextValue() { value = next }
    }
}
