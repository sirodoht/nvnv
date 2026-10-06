import Foundation
import NVNVCore

enum LibrarySwitcherAction {
    case open(NamedLibrary)
    case openInNewWindow(NamedLibrary)
    case add
    case rename(NamedLibrary)
    case remove(NamedLibrary)
}

/// Lightweight context only: inactive libraries never retain note bodies.
struct LibrarySession {
    struct NotePosition {
        let filename: String
        let fileIdentity: String?
        let range: NSRange
        let selected: Bool
    }

    let query: String
    let selectionKind: SelectionKind
    let suppressAutomaticSelection: Bool
    let positions: [NotePosition]

    init(notes: [Note], query: String, selection: Set<UUID>, selectionKind: SelectionKind,
         suppressAutomaticSelection: Bool) {
        self.query = query
        self.selectionKind = selectionKind
        self.suppressAutomaticSelection = suppressAutomaticSelection
        positions = notes.map { note in
            NotePosition(
                filename: note.filename, fileIdentity: note.fileIdentity,
                range: note.clampedSelection, selected: selection.contains(note.id)
            )
        }
    }

    func restorePositions(in notes: inout [Note]) -> Set<UUID> {
        let byIdentity = Dictionary(positions.compactMap { position in
            position.fileIdentity.map { ($0, position) }
        }, uniquingKeysWith: { first, _ in first })
        let byFilename = Dictionary(positions.map { ($0.filename, $0) }, uniquingKeysWith: { first, _ in first })
        var selected: Set<UUID> = []
        for index in notes.indices {
            let position = notes[index].fileIdentity.flatMap { byIdentity[$0] }
                ?? byFilename[notes[index].filename]
            guard let position else { continue }
            notes[index].cursorStart = position.range.location
            notes[index].cursorLength = position.range.length
            let clamped = notes[index].clampedSelection
            notes[index].cursorStart = clamped.location
            notes[index].cursorLength = clamped.length
            if position.selected { selected.insert(notes[index].id) }
        }
        return selected
    }
}
