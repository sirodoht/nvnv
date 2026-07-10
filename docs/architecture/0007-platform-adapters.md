# ADR 0007: Trash and Finder

- Status: accepted
- Trash: `FileManager.trashItem(at:resultingItemURL:)`
- Reveal: `NSWorkspace.activateFileViewerSelecting(_:)`
- Folder choice: `NSOpenPanel`

These APIs remain in the GUI/platform boundary. The core accepts protocols so
filesystem behavior can be tested against isolated temporary directories.
