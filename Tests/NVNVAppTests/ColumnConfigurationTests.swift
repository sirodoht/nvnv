import Foundation
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

    private func makeModel() -> AppModel {
        let suite = "nvnv-column-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return AppModel(userDefaults: defaults)
    }
}
