import NVNVCore
import Testing

@Suite("File change classification")
struct FileChangeClassifierTests {
    @Test func treatsAnInFlightAppSaveAsLocal() {
        let disposition = FileChangeClassifier.classify(
            diskHash: "new", lastSavedHash: "old",
            diskBody: "saved body", appBody: "newer unsaved body",
            isDirty: true, pendingLocalWriteHashes: ["new"]
        )

        #expect(disposition == .localWrite)
    }

    @Test func identicalBodiesNeverConflict() {
        let disposition = FileChangeClassifier.classify(
            diskHash: "new", lastSavedHash: "old",
            diskBody: "same body", appBody: "same body",
            isDirty: true, pendingLocalWriteHashes: []
        )

        #expect(disposition == .identicalContent)
    }

    @Test func differentConcurrentEditsStillConflict() {
        let disposition = FileChangeClassifier.classify(
            diskHash: "external", lastSavedHash: "old",
            diskBody: "file edit", appBody: "app edit",
            isDirty: true, pendingLocalWriteHashes: []
        )

        #expect(disposition == .conflict)
    }
}
