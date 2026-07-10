# ADR 0003: Text editor

- Status: accepted
- Implementation: `NSTextView` in a small `NSViewRepresentable`

SwiftUI owns note text and selection. AppKit owns text-system behavior and an
`UndoManager` per note. The bridge reports plain-text edits and cursor changes,
rejects rich-text state, and applies search highlighting as temporary layout
attributes. Coordinators are lifecycle glue only.
