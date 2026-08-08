import AppKit
import NVNVCore
import Testing
@testable import nvnv

@MainActor
@Suite("Note list column configuration")
struct ColumnConfigurationTests {
    @Test func normalizesDuplicatesAndRestoresMissingColumns() {
        #expect(AppModel.normalizedNoteListColumnOrder([.created, .title, .created]) == [
            .created, .title, .modified,
        ])
        #expect(AppModel.normalizedNoteListColumnOrder(nil) == [.title, .modified, .created])
    }

    @Test func defaultsToTitleThenModifiedWithNewestNotesFirst() {
        let model = makeModel()

        #expect(model.visibleNoteListColumns == [.title, .modified])
        #expect(model.sort == NoteSort(field: .modified, ascending: false))
    }

    @Test func reordersAColumnOnEitherSideOfItsDropTarget() {
        let model = makeModel()

        model.moveNoteListColumn(.title, relativeTo: .created, after: true)
        #expect(model.noteListColumnOrder == [.modified, .created, .title])

        model.moveNoteListColumn(.title, relativeTo: .modified, after: false)
        #expect(model.noteListColumnOrder == [.title, .modified, .created])
    }

    @Test func nativeVisibleOrderPreservesHiddenColumnPositions() {
        let model = makeModel()
        model.showModifiedDate = false
        model.showCreatedDate = true

        model.setVisibleNoteListColumnOrder([.created, .title])

        #expect(model.noteListColumnOrder == [.created, .modified, .title])
        #expect(model.visibleNoteListColumns == [.created, .title])
    }

    @Test func keepsAtLeastOneColumnVisibleAndMovesSortingOffAHiddenColumn() {
        let model = makeModel()
        model.sort = NoteSort(field: .title, ascending: true)

        model.setNoteListColumn(.title, visible: false)
        #expect(model.visibleNoteListColumns == [.modified])
        #expect(model.sort.field == .modified)

        model.setNoteListColumn(.modified, visible: false)
        #expect(model.visibleNoteListColumns == [.modified])
    }

    @Test func restoresPersistedFlexibleColumnWidthAndStillFillsTheViewport() {
        #expect(NoteListColumnWidthLayout.flexibleWidth(
            viewportWidth: 500,
            fixedWidth: 138,
            preferredWidth: 375.5,
            minimumWidth: 120
        ) == 375.5)
        #expect(NoteListColumnWidthLayout.flexibleWidth(
            viewportWidth: 600,
            fixedWidth: 138,
            preferredWidth: 375.5,
            minimumWidth: 120
        ) == 462)
    }

    @Test func centersNoteListTextWithinItsRow() {
        let cell = NoteListCellView(
            identifier: NSUserInterfaceItemIdentifier("layout-test"),
            leadingInset: 10
        )
        cell.frame = NSRect(x: 0, y: 0, width: 300, height: 16)
        cell.label.font = .systemFont(ofSize: 11)
        cell.layoutSubtreeIfNeeded()

        #expect(abs(cell.label.frame.midY - cell.bounds.midY) < 0.001)
    }

    @Test func topRequestUsesNativeHeaderGeometry() {
        let (scrollView, dataSource) = makeScrollView()
        _ = dataSource

        scrollView.scroll(rowTop: scrollView.noteTableView.frame.minY, in: scrollView.noteTableView)

        #expect(scrollView.contentView.bounds.minY == -NoteListScrollView.headerHeight)
        #expect(type(of: scrollView.contentView) == NSClipView.self)
        let row = scrollView.noteTableView.rect(ofRow: 0)
        #expect(row.minY - scrollView.contentView.bounds.minY == NoteListScrollView.headerHeight)
    }

    @Test func arbitraryRowTopAccountsForHeaderAndBottomConstraint() {
        let (scrollView, dataSource) = makeScrollView()
        _ = dataSource
        let tableView = scrollView.noteTableView

        let rowTenTop = tableView.rect(ofRow: 10).minY
        scrollView.scroll(rowTop: rowTenTop, in: tableView)
        #expect(scrollView.contentView.bounds.minY == rowTenTop - NoteListScrollView.headerHeight)
        #expect(rowTenTop - scrollView.contentView.bounds.minY == NoteListScrollView.headerHeight)

        let lastRowTop = tableView.rect(ofRow: tableView.numberOfRows - 1).minY
        var proposed = scrollView.contentView.bounds
        proposed.origin.y = lastRowTop - NoteListScrollView.headerHeight
        let expected = scrollView.contentView.constrainBoundsRect(proposed).minY
        scrollView.scroll(rowTop: lastRowTop, in: tableView)
        #expect(scrollView.contentView.bounds.minY == expected)
        #expect(expected < proposed.minY)
    }

    @Test func resizePreservesNativeTopWithoutDeferredFrameMutation() async {
        let (scrollView, dataSource) = makeScrollView()
        _ = dataSource
        scrollView.scroll(rowTop: scrollView.noteTableView.frame.minY, in: scrollView.noteTableView)

        scrollView.frame.size = NSSize(width: 527, height: 317.5)
        scrollView.layoutSubtreeIfNeeded()
        let frameAfterLayout = scrollView.contentView.frame
        await finishNextMainQueueTurn()

        #expect(scrollView.contentView.bounds.minY == -NoteListScrollView.headerHeight)
        #expect(scrollView.contentView.frame == frameAfterLayout)
    }

    @Test func finalNoteSeparatorIsExactlyOneDevicePixel() throws {
        let clip = NSRect(x: 0, y: 0, width: 300, height: 200)

        let retina = try #require(NoteListNativeTableView.finalSeparatorGeometry(
            rowsMaxY: 80,
            clipRect: clip,
            backingScaleFactor: 2
        ))
        #expect(retina.mask == NSRect(x: 0, y: 79, width: 300, height: 1))
        #expect(retina.hairline == NSRect(x: 0, y: 79.5, width: 300, height: 0.5))

        let standard = try #require(NoteListNativeTableView.finalSeparatorGeometry(
            rowsMaxY: 80,
            clipRect: clip,
            backingScaleFactor: 1
        ))
        #expect(standard.hairline == NSRect(x: 0, y: 79, width: 300, height: 1))
    }

    private func makeScrollView() -> (NoteListScrollView, NoteListDataSource) {
        let dataSource = NoteListDataSource()
        let scrollView = NoteListScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 249.5))
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        let tableView = scrollView.noteTableView
        tableView.dataSource = dataSource
        tableView.style = .plain
        tableView.rowHeight = 16
        tableView.intercellSpacing = .zero
        tableView.addTableColumn(NSTableColumn(identifier: .init("test")))
        scrollView.noteHeaderView.frame.size.height = NoteListScrollView.headerHeight
        tableView.headerView = scrollView.noteHeaderView
        scrollView.documentView = tableView
        scrollView.layoutSubtreeIfNeeded()
        return (scrollView, dataSource)
    }

    private func finishNextMainQueueTurn() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func makeModel() -> AppModel {
        let suite = "nvnv-column-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return AppModel(userDefaults: defaults)
    }
}

private final class NoteListDataSource: NSObject, NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int { 100 }
}
