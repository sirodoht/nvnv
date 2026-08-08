import Foundation

public struct CacheSnapshot: Sendable {
    public let notes: [Note]
    public let searchIndexIsValid: Bool

    public init(notes: [Note], searchIndexIsValid: Bool) {
        self.notes = notes
        self.searchIndexIsValid = searchIndexIsValid
    }
}

public struct CacheReconciliation: Sendable {
    public let indexedUpserts: [Note]
    public let metadataUpserts: [Note]
    public let removedIDs: Set<UUID>

    public init(cached: [Note], authoritative: [Note]) {
        let cachedByID = Dictionary(uniqueKeysWithValues: cached.map { ($0.id, $0) })
        let authoritativeIDs = Set(authoritative.map(\.id))
        removedIDs = Set(cachedByID.keys).subtracting(authoritativeIDs)

        var indexed: [Note] = []
        var metadata: [Note] = []
        indexed.reserveCapacity(authoritative.count)
        metadata.reserveCapacity(authoritative.count)
        for note in authoritative {
            guard let old = cachedByID[note.id] else {
                indexed.append(note)
                continue
            }
            if old.title != note.title || old.body != note.body {
                indexed.append(note)
            } else if old != note {
                metadata.append(note)
            }
        }
        indexedUpserts = indexed
        metadataUpserts = metadata
    }

    public var isEmpty: Bool {
        indexedUpserts.isEmpty && metadataUpserts.isEmpty && removedIDs.isEmpty
    }
}
