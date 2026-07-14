import Foundation

public enum FileChangeDisposition: Equatable, Sendable {
    case unchanged
    case localWrite
    case identicalContent
    case conflict
    case external
}

public enum FileChangeClassifier {
    public static func classify(
        diskHash: String,
        lastSavedHash: String,
        diskBody: String,
        appBody: String,
        isDirty: Bool,
        pendingLocalWriteHashes: Set<String>
    ) -> FileChangeDisposition {
        if diskHash == lastSavedHash { return .unchanged }
        if pendingLocalWriteHashes.contains(diskHash) { return .localWrite }
        if diskBody == appBody { return .identicalContent }
        return isDirty ? .conflict : .external
    }
}
