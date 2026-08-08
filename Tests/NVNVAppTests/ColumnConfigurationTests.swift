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

    @Test func tilesTheDocumentBelowTheHeaderAtLaunchAndAfterResize() async throws {
        let scrollView = NoteListScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 249.5))
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.contentView = NoteListClipView()
        scrollView.noteHeaderView.frame.size.height = NoteListScrollView.headerHeight
        scrollView.noteTableView.headerView = scrollView.noteHeaderView
        scrollView.noteTableView.frame.size.height = 1_000
        scrollView.documentView = scrollView.noteTableView

        scrollView.layoutSubtreeIfNeeded()
        await finishNextMainQueueTurn()
        try verifyHeaderAwareTiling(scrollView)

        scrollView.frame.size = NSSize(width: 527, height: 317.5)
        scrollView.layoutSubtreeIfNeeded()
        await finishNextMainQueueTurn()
        try verifyHeaderAwareTiling(scrollView)
    }

    @Test func preventsScrollingAboveTheFirstRow() {
        let clipView = NoteListClipView(frame: NSRect(x: 0, y: 0, width: 480, height: 200))
        let documentView = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 1_000))
        clipView.documentView = documentView

        let aboveDocument = NSRect(x: 0, y: -27, width: 480, height: 200)
        let constrainedTop = clipView.constrainBoundsRect(aboveDocument)
        #expect(constrainedTop.minY == documentView.frame.minY)

        let normalScroll = NSRect(x: 0, y: 160, width: 480, height: 200)
        let constrainedScroll = clipView.constrainBoundsRect(normalScroll)
        #expect(constrainedScroll.minY == normalScroll.minY)
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

    private func verifyHeaderAwareTiling(_ scrollView: NoteListScrollView) throws {
        let scroller = try #require(scrollView.verticalScroller)
        #expect(scrollView.noteHeaderView.frame.height == NoteListScrollView.headerHeight)
        #expect(abs(scrollView.contentView.frame.minY - scroller.frame.minY) < 0.001)
        #expect(abs(scrollView.contentView.frame.height - scroller.frame.height) < 0.001)
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
