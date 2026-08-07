import AppKit
import NVNVCore
import SwiftUI

struct NoteListView: View {
    @Bindable var model: AppModel
    @Environment(\.locale) private var locale
    @Environment(\.calendar) private var calendar
    @Environment(\.timeZone) private var timeZone
    @AppStorage("noteListTitleColumnWidth") private var titleColumnWidth = 0.0
    @AppStorage("noteListModifiedDateColumnWidth") private var modifiedColumnWidth = 150.0
    @AppStorage("noteListCreatedDateColumnWidth") private var createdColumnWidth = 130.0

    var body: some View {
        NativeNoteTable(
            model: model,
            results: model.results,
            selection: model.selection,
            selectionKind: model.selectionKind,
            columns: model.visibleNoteListColumns,
            sort: model.sort,
            scrollRequest: model.listScrollRequest,
            renameRequest: model.renameRequest,
            duplicateTitleKeys: model.duplicateTitleKeys,
            showExcerpts: model.showExcerpts,
            fontSize: 11,
            isReadOnly: model.isReadOnly,
            locale: locale,
            calendar: calendar,
            timeZone: timeZone,
            titleColumnWidth: $titleColumnWidth,
            modifiedColumnWidth: $modifiedColumnWidth,
            createdColumnWidth: $createdColumnWidth
        )
    }
}

enum NoteListColumnWidthLayout {
    static func flexibleWidth(
        viewportWidth: CGFloat,
        fixedWidth: CGFloat,
        preferredWidth: CGFloat,
        minimumWidth: CGFloat
    ) -> CGFloat {
        max(preferredWidth, viewportWidth - fixedWidth, minimumWidth)
    }
}

/// Finder and nvALT get smooth column movement because one `NSTableView` owns
/// both their headers and rows. Keeping that ownership intact also avoids
/// synchronizing drag snapshots between AppKit and SwiftUI during mouse tracking.
private struct NativeNoteTable: NSViewRepresentable {
    let model: AppModel
    let results: [SearchResult]
    let selection: Set<UUID>
    let selectionKind: SelectionKind
    let columns: [NoteListColumn]
    let sort: NoteSort
    let scrollRequest: ListScrollRequest?
    let renameRequest: RenameRequest?
    let duplicateTitleKeys: Set<String>
    let showExcerpts: Bool
    let fontSize: Double
    let isReadOnly: Bool
    let locale: Locale
    let calendar: Calendar
    let timeZone: TimeZone
    @Binding var titleColumnWidth: Double
    @Binding var modifiedColumnWidth: Double
    @Binding var createdColumnWidth: Double

    private let minimumTitleColumnWidth: CGFloat = 120
    private let minimumDateColumnWidth: CGFloat = 100

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NoteListScrollView {
        let scrollView = NoteListScrollView()
        context.coordinator.configure(scrollView)
        context.coordinator.synchronize(scrollView)
        return scrollView
    }

    func updateNSView(_ scrollView: NoteListScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.synchronize(scrollView)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
        var parent: NativeNoteTable

        private weak var scrollView: NoteListScrollView?
        private var isSynchronizingColumns = false
        private var isSynchronizingSelection = false
        private var isTrackingHeader = false
        private var pendingScrollRequestID: UUID?
        private var activeRenameRequestID: UUID?

        init(_ parent: NativeNoteTable) {
            self.parent = parent
        }

        func configure(_ scrollView: NoteListScrollView) {
            self.scrollView = scrollView

            scrollView.borderType = .noBorder
            scrollView.drawsBackground = true
            scrollView.backgroundColor = .controlBackgroundColor
            scrollView.hasVerticalScroller = true
            scrollView.hasHorizontalScroller = false
            scrollView.autohidesScrollers = true

            let tableView = scrollView.noteTableView
            tableView.dataSource = self
            tableView.delegate = self
            tableView.allowsMultipleSelection = true
            tableView.allowsEmptySelection = true
            tableView.allowsColumnSelection = false
            tableView.allowsColumnReordering = true
            tableView.allowsColumnResizing = true
            // Widths are restored explicitly below. Letting AppKit distribute a
            // later frame change across every column turns the saved 70/30 split
            // into 50/50 during launch.
            tableView.columnAutoresizingStyle = .noColumnAutoresizing
            tableView.style = .plain
            tableView.selectionHighlightStyle = .regular
            tableView.focusRingType = .none
            tableView.rowHeight = 16
            tableView.intercellSpacing = .zero
            tableView.gridStyleMask = [.solidHorizontalGridLineMask]
            tableView.gridColor = .separatorColor
            tableView.backgroundColor = .controlBackgroundColor
            tableView.headerView = scrollView.noteHeaderView
            tableView.autoresizingMask = [.width]

            scrollView.documentView = tableView
            scrollView.onLayout = { [weak self, weak scrollView] in
                guard let self, let scrollView, !self.isTrackingHeader else { return }
                self.synchronizeColumnWidths(scrollView.noteTableView, viewportWidth: scrollView.contentSize.width)
            }
            scrollView.noteHeaderView.menuProvider = { [weak self] in self?.columnMenu() }
            scrollView.noteHeaderView.onTrackingChanged = { [weak self, weak scrollView] tracking in
                guard let self, let scrollView else { return }
                self.isTrackingHeader = tracking
                // During a real divider drag, preserve AppKit's native behavior
                // of balancing the other columns to keep the table fitted.
                scrollView.noteTableView.columnAutoresizingStyle = tracking
                    ? .uniformColumnAutoresizingStyle
                    : .noColumnAutoresizing
                if !tracking {
                    // SwiftUI publishes model mutations after AppKit's mouse
                    // tracking loop returns. Reconcile on that next turn.
                    DispatchQueue.main.async { self.synchronize(scrollView) }
                }
            }
            tableView.contextMenuProvider = { [weak self] row in self?.rowMenu(for: row) }
            tableView.willOpenContextMenu = { [weak self] row in self?.prepareContextSelection(row: row) }
            tableView.onEnter = { [weak self] in
                self?.parent.model.focusSelectedNoteEditor() ?? false
            }
        }

        func synchronize(_ scrollView: NoteListScrollView) {
            // Rebuilding columns or cells while the native header owns the mouse
            // corrupts AppKit's drag snapshots. The table already moves its rows
            // and header as one unit, so it stays authoritative until mouse-up.
            guard !isTrackingHeader else { return }

            let tableView = scrollView.noteTableView
            reconcileColumns(in: tableView)
            synchronizeColumnWidths(tableView, viewportWidth: scrollView.contentSize.width)
            synchronizeSortIndicator(in: tableView)
            tableView.rowHeight = max(16, CGFloat(parent.fontSize) + 5)
            cancelRenameIfNeeded(in: tableView)
            if tableView.editedRow < 0 { tableView.reloadData() }
            synchronizeSelection(in: tableView)
            fulfillScrollRequest(in: tableView, scrollView: scrollView)

            // reloadData() updates AppKit's row/cell accessibility tree, but it
            // does not reliably invalidate the enclosing clip view when focus
            // moves to the editor in the same run-loop turn. The populated row
            // then remains visually blank until the window is resized. Perform
            // the layout/display invalidation that a resize would trigger.
            DispatchQueue.main.async { [weak self, weak tableView, weak scrollView] in
                guard let self, let tableView, let scrollView else { return }
                // Focus has finished moving by this turn. Rebuild the native row
                // views now, rather than leaving the correctly-populated but
                // unpainted views created during the focus transition.
                if tableView.editedRow < 0 { tableView.reloadData() }
                self.synchronizeSelection(in: tableView)
                tableView.needsLayout = true
                scrollView.needsLayout = true
                let displayRoot = scrollView.window?.contentView ?? scrollView
                displayRoot.needsLayout = true
                displayRoot.layoutSubtreeIfNeeded()
                displayRoot.setNeedsDisplay(displayRoot.bounds)
                scrollView.window?.displayIfNeeded()
                self.beginRenameIfNeeded(in: tableView)
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { parent.results.count }

        // NSTableView only enables cell editing when its data source implements
        // this setter. The text-field delegate below owns commit/cancel so it can
        // preserve the note identity across an asynchronous filesystem rename.
        func tableView(
            _ tableView: NSTableView,
            setObjectValue object: Any?,
            for tableColumn: NSTableColumn?,
            row: Int
        ) {}

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard parent.results.indices.contains(row),
                  let tableColumn,
                  let column = NoteListColumn(rawValue: tableColumn.identifier.rawValue) else { return nil }

            let identifier = NSUserInterfaceItemIdentifier("note-list-\(column.rawValue)")
            let cell = (tableView.makeView(withIdentifier: identifier, owner: nil) as? NoteListCellView)
                ?? NoteListCellView(
                    identifier: identifier,
                    leadingInset: column == .title ? 10 : 9
                )
            configure(cell, column: column, result: parent.results[row])
            return cell
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let rowView = NoteListRowView()
            if parent.results.indices.contains(row) {
                let id = parent.results[row].id
                rowView.showsAutomaticSelection = parent.selectionKind == .automatic && parent.selection.contains(id)
            }
            return rowView
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isSynchronizingSelection,
                  let tableView = notification.object as? NSTableView else { return }
            let ids = Set(tableView.selectedRowIndexes.compactMap { row in
                parent.results.indices.contains(row) ? parent.results[row].id : nil
            })
            parent.model.select(ids)
        }

        func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
            guard !isSynchronizingColumns,
                  let column = NoteListColumn(rawValue: tableColumn.identifier.rawValue) else { return }
            let field = column.sortField
            let ascending = parent.model.sort.field == field ? !parent.model.sort.ascending : column == .title
            parent.model.sort = NoteSort(field: field, ascending: ascending)
            synchronizeSortIndicator(in: tableView)
        }

        func tableViewColumnDidMove(_ notification: Notification) {
            guard !isSynchronizingColumns,
                  let tableView = notification.object as? NSTableView else { return }
            parent.model.setVisibleNoteListColumnOrder(tableView.tableColumns.compactMap {
                NoteListColumn(rawValue: $0.identifier.rawValue)
            })
        }

        func tableViewColumnDidResize(_ notification: Notification) {
            guard isTrackingHeader,
                  !isSynchronizingColumns,
                  let tableView = notification.object as? NSTableView else { return }
            for tableColumn in tableView.tableColumns {
                guard let column = NoteListColumn(rawValue: tableColumn.identifier.rawValue) else { continue }
                let width = Double(max(tableColumn.width, minimumWidth(for: column)))
                switch column {
                case .title: parent.titleColumnWidth = width
                case .modified: parent.modifiedColumnWidth = width
                case .created: parent.createdColumnWidth = width
                }
            }
        }

        private func configure(_ cell: NoteListCellView, column: NoteListColumn, result: SearchResult) {
            cell.noteID = result.note.id
            cell.column = column
            cell.label.delegate = self
            cell.label.isEditable = false
            switch column {
            case .title:
                let titleFont = NSFont.systemFont(ofSize: parent.fontSize)
                cell.label.font = titleFont
                cell.label.textColor = .labelColor
                let title = NSMutableAttributedString(
                    string: result.note.title,
                    attributes: [
                        .font: titleFont,
                        .foregroundColor: NSColor.labelColor,
                    ]
                )
                if parent.duplicateTitleKeys.contains(TextNormalizer.normalize(result.note.title)) {
                    title.append(NSAttributedString(
                        string: "  \(result.note.filename)",
                        attributes: [
                            .font: NSFont.systemFont(ofSize: max(9, parent.fontSize - 2)),
                            .foregroundColor: NSColor.secondaryLabelColor,
                        ]
                    ))
                }
                if parent.showExcerpts, !result.excerpt.isEmpty {
                    title.append(NSAttributedString(
                        string: "  — \(result.excerpt)",
                        attributes: [
                            .font: NSFont.systemFont(ofSize: max(10, parent.fontSize - 1)),
                            .foregroundColor: NSColor.secondaryLabelColor,
                        ]
                    ))
                }
                let paragraphStyle = NSMutableParagraphStyle()
                paragraphStyle.lineBreakMode = .byTruncatingTail
                title.addAttribute(
                    .paragraphStyle,
                    value: paragraphStyle,
                    range: NSRange(location: 0, length: title.length)
                )
                cell.label.attributedStringValue = title
            case .modified:
                configureDateLabel(cell.label, date: result.note.modifiedAt)
            case .created:
                configureDateLabel(cell.label, date: result.note.createdAt)
            }
        }

        private func configureDateLabel(_ label: NSTextField, date: Date) {
            label.stringValue = PresentationDateCache.shared.string(
                for: date,
                locale: parent.locale,
                calendar: parent.calendar,
                timeZone: parent.timeZone
            )
            label.font = .systemFont(ofSize: parent.fontSize)
            label.textColor = .secondaryLabelColor
        }

        private func reconcileColumns(in tableView: NSTableView) {
            isSynchronizingColumns = true
            defer { isSynchronizingColumns = false }

            let visible = Set(parent.columns)
            for tableColumn in tableView.tableColumns.reversed() {
                guard let column = NoteListColumn(rawValue: tableColumn.identifier.rawValue),
                      !visible.contains(column) else { continue }
                tableView.removeTableColumn(tableColumn)
            }
            for column in parent.columns where tableColumn(for: column, in: tableView) == nil {
                tableView.addTableColumn(makeTableColumn(column))
            }
            for (targetIndex, column) in parent.columns.enumerated() {
                guard let currentIndex = tableView.tableColumns.firstIndex(where: {
                    $0.identifier.rawValue == column.rawValue
                }), currentIndex != targetIndex else { continue }
                tableView.moveColumn(currentIndex, toColumn: targetIndex)
            }
        }

        private func makeTableColumn(_ column: NoteListColumn) -> NSTableColumn {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            tableColumn.isEditable = column == .title
            tableColumn.headerCell = NoteListHeaderCell(
                title: column.title,
                leadingInset: column == .title ? 14 : 9
            )
            tableColumn.minWidth = column == .title ? parent.minimumTitleColumnWidth : parent.minimumDateColumnWidth
            return tableColumn
        }

        private func tableColumn(for column: NoteListColumn, in tableView: NSTableView) -> NSTableColumn? {
            tableView.tableColumns.first { $0.identifier.rawValue == column.rawValue }
        }

        private func synchronizeColumnWidths(_ tableView: NSTableView, viewportWidth: CGFloat) {
            guard !parent.columns.isEmpty, viewportWidth > 0 else { return }
            isSynchronizingColumns = true
            defer { isSynchronizingColumns = false }

            let flexible = parent.columns.contains(.title) ? NoteListColumn.title : parent.columns[0]
            let fixedColumns = parent.columns.filter { $0 != flexible }
            let fixedWidth = fixedColumns.reduce(CGFloat.zero) { width, column in
                width + desiredWidth(for: column)
            }
            let flexibleMinimum = flexible == .title
                ? parent.minimumTitleColumnWidth
                : parent.minimumDateColumnWidth
            let flexibleWidth = NoteListColumnWidthLayout.flexibleWidth(
                viewportWidth: viewportWidth,
                fixedWidth: fixedWidth,
                preferredWidth: desiredWidth(for: flexible),
                minimumWidth: flexibleMinimum
            )

            for column in parent.columns {
                guard let tableColumn = tableColumn(for: column, in: tableView) else { continue }
                tableColumn.resizingMask = [.userResizingMask, .autoresizingMask]
                tableColumn.maxWidth = .greatestFiniteMagnitude
                let width = column == flexible ? flexibleWidth : desiredWidth(for: column)
                if abs(tableColumn.width - width) > 0.5 { tableColumn.width = width }
            }
            tableView.frame.size.width = max(viewportWidth, parent.columns.reduce(0) {
                $0 + (tableColumn(for: $1, in: tableView)?.width ?? 0)
            })
        }

        private func desiredWidth(for column: NoteListColumn) -> CGFloat {
            switch column {
            case .title:
                parent.titleColumnWidth > 0
                    ? max(CGFloat(parent.titleColumnWidth), parent.minimumTitleColumnWidth)
                    : parent.minimumTitleColumnWidth
            case .modified: max(CGFloat(parent.modifiedColumnWidth), parent.minimumDateColumnWidth)
            case .created: max(CGFloat(parent.createdColumnWidth), parent.minimumDateColumnWidth)
            }
        }

        private func minimumWidth(for column: NoteListColumn) -> CGFloat {
            column == .title ? parent.minimumTitleColumnWidth : parent.minimumDateColumnWidth
        }

        private func synchronizeSortIndicator(in tableView: NSTableView) {
            for column in tableView.tableColumns { tableView.setIndicatorImage(nil, in: column) }
            guard let sortedColumn = tableView.tableColumns.first(where: {
                NoteListColumn(rawValue: $0.identifier.rawValue)?.sortField == parent.sort.field
            }) else {
                tableView.highlightedTableColumn = nil
                return
            }
            let name = parent.sort.ascending ? "NSAscendingSortIndicator" : "NSDescendingSortIndicator"
            tableView.setIndicatorImage(NSImage(named: NSImage.Name(name)), in: sortedColumn)
            tableView.highlightedTableColumn = sortedColumn
        }

        private func synchronizeSelection(in tableView: NSTableView) {
            let selectedRows: IndexSet
            if parent.selectionKind == .explicit {
                selectedRows = IndexSet(parent.results.indices.filter { parent.selection.contains(parent.results[$0].id) })
            } else {
                selectedRows = []
            }
            guard tableView.selectedRowIndexes != selectedRows else { return }
            isSynchronizingSelection = true
            tableView.selectRowIndexes(selectedRows, byExtendingSelection: false)
            isSynchronizingSelection = false
        }

        private func fulfillScrollRequest(in tableView: NSTableView, scrollView: NSScrollView) {
            guard let request = parent.scrollRequest,
                  pendingScrollRequestID != request.id else { return }
            pendingScrollRequestID = request.id
            DispatchQueue.main.async { [weak self, weak tableView, weak scrollView] in
                guard let self, let tableView, let scrollView,
                      self.parent.scrollRequest?.id == request.id else { return }
                defer {
                    self.parent.model.consumeListScrollRequest(request.id)
                    self.pendingScrollRequestID = nil
                }
                switch request.target {
                case .note(let noteID, let placement):
                    guard let row = self.parent.results.firstIndex(where: { $0.id == noteID }) else { return }
                    switch placement {
                    case .minimal:
                        tableView.scrollRowToVisible(row)
                    case .top:
                        let rowRect = tableView.rect(ofRow: row)
                        scrollView.contentView.scroll(to: NSPoint(x: 0, y: rowRect.minY))
                        scrollView.reflectScrolledClipView(scrollView.contentView)
                    }
                case .top:
                    scrollView.contentView.scroll(to: .zero)
                    scrollView.reflectScrolledClipView(scrollView.contentView)
                }
            }
        }

        private func cancelRenameIfNeeded(in tableView: NSTableView) {
            guard parent.renameRequest == nil,
                  activeRenameRequestID != nil,
                  tableView.editedRow >= 0 else { return }
            if let cell = tableView.view(
                atColumn: tableView.editedColumn,
                row: tableView.editedRow,
                makeIfNecessary: false
            ) as? NoteListCellView {
                cell.label.isEditable = false
                cell.label.isSelectable = false
            }
            tableView.abortEditing()
            activeRenameRequestID = nil
        }

        private func beginRenameIfNeeded(in tableView: NSTableView) {
            guard let request = parent.renameRequest else {
                activeRenameRequestID = nil
                return
            }
            guard activeRenameRequestID != request.id || tableView.editedRow < 0,
                  let row = parent.results.firstIndex(where: { $0.id == request.noteID }),
                  let column = tableView.tableColumns.firstIndex(where: {
                      $0.identifier.rawValue == NoteListColumn.title.rawValue
                  }),
                  let cell = tableView.view(atColumn: column, row: row, makeIfNecessary: true)
                    as? NoteListCellView else { return }

            activeRenameRequestID = request.id
            tableView.scrollRowToVisible(row)
            cell.label.isEditable = true
            cell.label.isSelectable = true
            cell.label.stringValue = parent.results[row].note.title
            tableView.editColumn(column, row: row, with: nil, select: true)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField,
                  let cell = field.superview as? NoteListCellView,
                  cell.column == .title,
                  let noteID = cell.noteID,
                  parent.renameRequest?.noteID == noteID else { return }

            field.isEditable = false
            field.isSelectable = false
            activeRenameRequestID = nil
            let movement = (notification.userInfo?["NSTextMovement"] as? NSNumber)?.intValue
            if movement == NSTextMovement.cancel.rawValue {
                parent.model.cancelRename()
            } else {
                let proposedTitle = field.stringValue
                Task { await parent.model.commitRename(to: proposedTitle) }
            }
        }

        private func prepareContextSelection(row: Int) {
            guard parent.results.indices.contains(row), let tableView = scrollView?.noteTableView else { return }
            if !tableView.selectedRowIndexes.contains(row) {
                isSynchronizingSelection = true
                tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                isSynchronizingSelection = false
                parent.model.select([parent.results[row].id])
            }
        }

        private func rowMenu(for row: Int) -> NSMenu? {
            guard parent.results.indices.contains(row) else { return nil }
            let menu = NSMenu()
            let rename = NSMenuItem(title: "Rename", action: #selector(renameNote(_:)), keyEquivalent: "")
            rename.target = self
            rename.isEnabled = !parent.isReadOnly && parent.model.selection.count == 1
            menu.addItem(rename)

            let reveal = NSMenuItem(title: "Show in Finder", action: #selector(revealNote(_:)), keyEquivalent: "")
            reveal.target = self
            reveal.isEnabled = parent.model.selection.count == 1
            menu.addItem(reveal)
            menu.addItem(.separator())

            let trash = NSMenuItem(title: "Move to Trash", action: #selector(trashNotes(_:)), keyEquivalent: "")
            trash.target = self
            trash.isEnabled = !parent.isReadOnly && !parent.model.selection.isEmpty
            menu.addItem(trash)
            return menu
        }

        private func columnMenu() -> NSMenu {
            let menu = NSMenu()
            let visibleCount = parent.model.visibleNoteListColumns.count
            for column in NoteListColumn.allCases {
                let item = NSMenuItem(title: column.title, action: #selector(toggleColumn(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = column.rawValue
                let visible = parent.model.isNoteListColumnVisible(column)
                item.state = visible ? .on : .off
                item.isEnabled = !visible || visibleCount > 1
                menu.addItem(item)
            }
            return menu
        }

        @objc private func renameNote(_ sender: NSMenuItem) { parent.model.startRename() }
        @objc private func revealNote(_ sender: NSMenuItem) { parent.model.revealSelectedNote() }
        @objc private func trashNotes(_ sender: NSMenuItem) { Task { await parent.model.deleteSelection() } }

        @objc private func toggleColumn(_ sender: NSMenuItem) {
            guard let rawValue = sender.representedObject as? String,
                  let column = NoteListColumn(rawValue: rawValue) else { return }
            parent.model.setNoteListColumn(column, visible: !parent.model.isNoteListColumnVisible(column))
        }
    }
}

private final class NoteListScrollView: NSScrollView {
    let noteTableView = NoteListNativeTableView()
    let noteHeaderView = NoteListTableHeaderView()
    var onLayout: (() -> Void)?

    override func layout() {
        super.layout()
        if noteHeaderView.frame.height != 27 {
            noteHeaderView.frame.size.height = 27
            tile()
        }
        onLayout?()
    }
}

final class NoteListNativeTableView: NSTableView {
    var contextMenuProvider: ((Int) -> NSMenu?)?
    var willOpenContextMenu: ((Int) -> Void)?
    var onEnter: (() -> Bool)?

    override func keyDown(with event: NSEvent) {
        let isEnter = event.keyCode == 36 || event.keyCode == 76
        let hasConflictingModifier = !event.modifierFlags
            .intersection([.command, .control, .option])
            .isEmpty
        if isEnter, !hasConflictingModifier, onEnter?() == true { return }
        super.keyDown(with: event)
    }

    override func drawGrid(inClipRect clipRect: NSRect) {
        guard numberOfRows > 0 else { return }
        var populatedRowsRect = clipRect
        let rowsMaxY = rect(ofRow: numberOfRows - 1).maxY
        populatedRowsRect.size.height = min(clipRect.maxY, rowsMaxY) - clipRect.minY
        guard populatedRowsRect.height > 0 else { return }
        super.drawGrid(inClipRect: populatedRowsRect)

        let finalSeparator = NSRect(
            x: clipRect.minX,
            y: rowsMaxY - 1,
            width: clipRect.width,
            height: 1
        )
        guard finalSeparator.intersects(clipRect) else { return }
        backgroundColor.setFill()
        finalSeparator.fill()
        gridColor.setFill()
        finalSeparator.fill()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: point)
        guard clickedRow >= 0 else { return nil }
        willOpenContextMenu?(clickedRow)
        return contextMenuProvider?(clickedRow)
    }
}

private final class NoteListTableHeaderView: NSTableHeaderView {
    var menuProvider: (() -> NSMenu?)?
    var onTrackingChanged: ((Bool) -> Void)?

    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }

    override func mouseDown(with event: NSEvent) {
        onTrackingChanged?(true)
        defer { onTrackingChanged?(false) }
        super.mouseDown(with: event)
    }
}

final class NoteListCellView: NSTableCellView {
    let label = NSTextField(frame: .zero)
    var noteID: UUID?
    var column: NoteListColumn?

    init(identifier: NSUserInterfaceItemIdentifier, leadingInset: CGFloat) {
        super.init(frame: .zero)
        self.identifier = identifier
        label.translatesAutoresizingMaskIntoConstraints = false
        label.isEditable = false
        label.isSelectable = false
        label.drawsBackground = false
        label.isBezeled = false
        label.isBordered = false
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.usesSingleLineMode = true
        label.cell?.lineBreakMode = .byTruncatingTail
        label.cell?.truncatesLastVisibleLine = true
        label.cell?.wraps = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: leadingInset),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        textField = label
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private final class NoteListHeaderCell: NSTableHeaderCell {
    private let leadingInset: CGFloat

    init(title: String, leadingInset: CGFloat) {
        self.leadingInset = leadingInset
        super.init(textCell: title)
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        var insetFrame = cellFrame
        insetFrame.origin.x += leadingInset
        insetFrame.size.width = max(insetFrame.width - leadingInset, 0)
        super.drawInterior(withFrame: insetFrame, in: controlView)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private final class NoteListRowView: NSTableRowView {
    var showsAutomaticSelection = false

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard showsAutomaticSelection, !isSelected else { return }
        NSColor.selectedContentBackgroundColor.withAlphaComponent(0.28).setFill()
        dirtyRect.fill()
    }
}
