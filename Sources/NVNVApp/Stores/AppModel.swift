import AppKit
import Foundation
import NVNVCore
import Observation
import OSLog

@MainActor
@Observable
final class AppModel {
    var libraryURL: URL?
    private(set) var isRestoringLibrary: Bool
    var notes: [Note] = []
    var results: [SearchResult] = []
    var selection: Set<UUID> = []
    var selectionKind: SelectionKind = .none
    var searchText = "" {
        didSet {
            if !isShowingSelectedNoteTitle, query != searchText { query = searchText }
        }
    }
    private(set) var query = "" {
        didSet { refreshSearch() }
    }
    var sort = NoteSort() { didSet { refreshSearch(); persistSettingsSoon() } }
    var isReadOnly = false
    var isIndexing = false
    var scanIssues: [ScanIssue] = []
    var errorMessage: String?
    var transientMessage: String?
    var conflict: Conflict? {
        didSet { isConflictPresented = conflict != nil }
    }
    var isConflictPresented = false
    var isRenaming = false
    private(set) var isShowingSelectedNoteTitle = false
    var focusSearchGeneration = 0
    var editorFocusRequest: EditorFocusRequest?
    var listScrollRequest: ListScrollRequest?
    var renameRequest: RenameRequest?
    var dividerFraction = 0.36 { didSet { persistSettingsSoon() } }
    var showTitleColumn = true { didSet { persistSettingsSoon() } }
    var showModifiedDate = true { didSet { persistSettingsSoon() } }
    var showCreatedDate = false { didSet { persistSettingsSoon() } }
    var noteListColumnOrder: [NoteListColumn] = [.title, .modified, .created] {
        didSet { persistSettingsSoon() }
    }
    var showExcerpts = true { didSet { persistSettingsSoon() } }
    var confirmDeletion = true { didSet { persistSettingsSoon() } }
    var highlightSearch = true { didSet { persistSettingsSoon() } }
    var editorFontName = "" { didSet { persistSettingsSoon() } }
    var editorFontSize = 12.0 { didSet { persistSettingsSoon() } }
    var softTabs = false { didSet { persistSettingsSoon() } }
    var tabWidth = 4 { didSet { persistSettingsSoon() } }
    var tabIndents = true { didSet { persistSettingsSoon() } }
    var extensionList = "txt" { didSet { persistSettingsSoon() } }
    var defaultExtension = "txt" { didSet { persistSettingsSoon() } }
    var editorCommand: EditorCommand?
    var editorCommandGeneration = 0
    private(set) var undoInvalidationGenerations: [UUID: Int] = [:]
    private(set) var duplicateTitleKeys: Set<String> = []

    private let logger = Logger(subsystem: "app.nvnv", category: "library")
    private let scanner = LibraryScanner()
    private let userDefaults: UserDefaults
    private var repository: FileRepository?
    private var cache: SQLiteCache?
    private var journal: RecoveryJournal?
    private var settingsRepository: SettingsRepository?
    private var libraryLock: LibraryLock?
    private var watcher: DirectoryWatcher?
    private var reconcileGeneration = 0
    private var searchGeneration = 0
    private var searchTask: Task<Void, Never>?
    private var visibleResultTask: Task<Void, Never>?
    private var searchDocuments: [UUID: SearchDocument] = [:] {
        didSet { searchDocumentsGeneration &+= 1 }
    }
    private var searchDocumentsGeneration: UInt = 0
    private var lastAppliedSearchDocumentsGeneration: UInt?
    private var lastAppliedSearchQuery: SearchQuery?
    private var staleSearchDocumentIDs: Set<UUID> = []
    private var cacheIndexedSearchVersions: [UUID: SearchIndexVersion] = [:]
    private var saveTasks: [UUID: Task<Void, Never>] = [:]
    private var deadlineTasks: [UUID: Task<Void, Never>] = [:]
    private var savingNoteIDs: Set<UUID> = []
    private var journalTasks: [UUID: Task<Void, Never>] = [:]
    private var journalDeadlineTasks: [UUID: Task<Void, Never>] = [:]
    private var journalOperations: [UUID: Task<Void, Never>] = [:]
    private var journalOperationIDs: [UUID: UUID] = [:]
    private var lastJournaledRevision: [UUID: Int] = [:]
    private var journalIDs: [UUID: UUID] = [:]
    private var baseBodies: [UUID: String] = [:]
    private var dirtyNoteIDs: Set<UUID> = []
    private var pendingLocalWriteHashes: [UUID: Set<String>] = [:]
    private var queuedConflicts: [UUID: Conflict] = [:]
    private var queuedConflictOrder: [UUID] = []
    private var settingsTask: Task<Void, Never>?
    private var pendingListResort = false
    private var scrollToTopAfterNextSearch = false
    private var navigationHistory: [(String, Set<UUID>)] = []

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        isRestoringLibrary = userDefaults.string(forKey: "lastLibraryPath") != nil
    }

    var selectedNote: Note? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return notes.first { $0.id == id }
    }

    var selectedResult: SearchResult? {
        guard let id = selectedNote?.id else { return nil }
        return results.first { $0.id == id }
    }

    var selectedEditorMatchRanges: [NSRange] {
        guard highlightSearch, !isShowingSelectedNoteTitle else { return [] }
        return selectedResult?.bodyRanges ?? []
    }

    var recognizedExtensions: Set<String> {
        let parsed = extensionList.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        }.filter { !$0.isEmpty }
        return Set(parsed).union([defaultExtension.lowercased()])
    }

    var visibleNoteListColumns: [NoteListColumn] {
        noteListColumnOrder.filter(isNoteListColumnVisible)
    }

    func isNoteListColumnVisible(_ column: NoteListColumn) -> Bool {
        switch column {
        case .title: showTitleColumn
        case .modified: showModifiedDate
        case .created: showCreatedDate
        }
    }

    func setNoteListColumn(_ column: NoteListColumn, visible: Bool) {
        guard visible || visibleNoteListColumns.count > 1 else { return }
        switch column {
        case .title: showTitleColumn = visible
        case .modified: showModifiedDate = visible
        case .created: showCreatedDate = visible
        }

        guard !visible, sort.field == column.sortField,
              let replacement = visibleNoteListColumns.first else { return }
        sort = NoteSort(field: replacement.sortField, ascending: replacement == .title)
    }

    func moveNoteListColumn(_ source: NoteListColumn, relativeTo target: NoteListColumn, after: Bool) {
        guard source != target,
              let sourceIndex = noteListColumnOrder.firstIndex(of: source),
              noteListColumnOrder.contains(target) else { return }
        var reordered = noteListColumnOrder
        reordered.remove(at: sourceIndex)
        guard let adjustedTargetIndex = reordered.firstIndex(of: target) else { return }
        reordered.insert(source, at: adjustedTargetIndex + (after ? 1 : 0))
        noteListColumnOrder = reordered
    }

    func setVisibleNoteListColumnOrder(_ visibleOrder: [NoteListColumn]) {
        guard Set(visibleOrder) == Set(visibleNoteListColumns) else { return }
        var iterator = visibleOrder.makeIterator()
        noteListColumnOrder = noteListColumnOrder.map { column in
            isNoteListColumnVisible(column) ? (iterator.next() ?? column) : column
        }
    }

    func restoreLastLibrary() async {
        guard libraryURL == nil else {
            isRestoringLibrary = false
            return
        }
        guard let path = userDefaults.string(forKey: "lastLibraryPath") else {
            isRestoringLibrary = false
            return
        }
        defer { isRestoringLibrary = false }
        await openLibrary(URL(fileURLWithPath: path), confirmedAuxiliaryCreation: true)
    }

    func chooseLibrary() async {
        let panel = NSOpenPanel()
        panel.title = "Choose Notes Folder"
        panel.prompt = "Open Library"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let auxiliary = url.appendingPathComponent(".nvnv")
        var confirmed = FileManager.default.fileExists(atPath: auxiliary.path)
        if !confirmed {
            let alert = NSAlert()
            alert.icon = NSImage(systemSymbolName: "note.text", accessibilityDescription: "nvnv")
            alert.messageText = "Use this folder as an nvnv library?"
            alert.informativeText = "nvnv will create a hidden .nvnv folder for its disposable index, settings, and crash recovery data. Existing text files will not be changed."
            alert.addButton(withTitle: "Open Library")
            alert.addButton(withTitle: "Cancel")
            confirmed = alert.runModal() == .alertFirstButtonReturn
        }
        if confirmed { await openLibrary(url, confirmedAuxiliaryCreation: true) }
    }

    func forgetLibrary() async {
        guard libraryURL != nil else { return }
        do {
            try await flushAll()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return
        }

        searchTask?.cancel()
        visibleResultTask?.cancel()
        settingsTask?.cancel()
        for task in deadlineTasks.values { task.cancel() }
        deadlineTasks.removeAll()
        reconcileGeneration += 1

        watcher = nil
        libraryLock = nil
        repository = nil
        cache = nil
        journal = nil
        settingsRepository = nil
        isRestoringLibrary = false
        libraryURL = nil
        notes = []
        results = []
        selection = []
        selectionKind = .none
        searchText = ""
        query = ""
        searchDocuments = [:]
        staleSearchDocumentIDs = []
        cacheIndexedSearchVersions = [:]
        baseBodies = [:]
        dirtyNoteIDs = []
        pendingLocalWriteHashes = [:]
        undoInvalidationGenerations = [:]
        savingNoteIDs = []
        lastJournaledRevision = [:]
        journalIDs = [:]
        journalOperations = [:]
        journalOperationIDs = [:]
        duplicateTitleKeys = []
        navigationHistory = []
        scanIssues = []
        queuedConflicts = [:]
        queuedConflictOrder = []
        conflict = nil
        isConflictPresented = false
        isReadOnly = false
        isIndexing = false
        isRenaming = false
        isShowingSelectedNoteTitle = false
        editorFocusRequest = nil
        listScrollRequest = nil
        renameRequest = nil
        errorMessage = nil
        transientMessage = nil
        userDefaults.removeObject(forKey: "lastLibraryPath")
    }

    func confirmAndForgetLibrary() async {
        guard libraryURL != nil else { return }
        let alert = NSAlert()
        alert.messageText = "Forget this library?"
        alert.informativeText = "nvnv will return to the welcome screen and stop remembering this folder. Your notes and the folder’s .nvnv data will remain untouched."
        alert.addButton(withTitle: "Forget Library")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        await forgetLibrary()
    }

    func resetSettings() async {
        guard let settingsRepository else { return }
        let defaults = LibrarySettings()
        apply(defaults)
        cancelRename()
        isShowingSelectedNoteTitle = false
        searchText = defaults.query
        query = defaults.query
        selection = defaults.selectedNoteIDs
        selectionKind = defaults.selectionKind
        navigationHistory = []
        for key in [
            "noteListTitleColumnWidth",
            "noteListModifiedDateColumnWidth",
            "noteListCreatedDateColumnWidth",
        ] {
            userDefaults.removeObject(forKey: key)
        }
        settingsTask?.cancel()
        do {
            try await settingsRepository.save(settingsSnapshot())
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func openLibrary(_ url: URL, confirmedAuxiliaryCreation: Bool) async {
        guard confirmedAuxiliaryCreation else { return }
        let selectedURL = url.standardizedFileURL.resolvingSymlinksInPath()
        if let libraryURL,
           libraryURL.standardizedFileURL.resolvingSymlinksInPath() == selectedURL {
            focusSearch()
            return
        }
        do {
            try await flushAll()
            try scanner.validate(selectedURL)
            let auxiliary = selectedURL.appendingPathComponent(".nvnv", isDirectory: true)
            try FileManager.default.createDirectory(at: auxiliary, withIntermediateDirectories: true)
            let lock = try LibraryLock(auxiliaryDirectory: auxiliary)
            let writable = lock.isWritable
            let settingsRepository = SettingsRepository(url: auxiliary.appendingPathComponent("settings.json"))
            let settings = await settingsRepository.load()
            apply(settings)

            var cache: SQLiteCache?
            do { cache = try SQLiteCache(url: auxiliary.appendingPathComponent("index.sqlite3"), readOnly: !writable) }
            catch {
                logger.error("Cache unavailable: \(String(describing: error), privacy: .public)")
                if writable {
                    let broken = auxiliary.appendingPathComponent("index.sqlite3.broken-\(Int(Date.now.timeIntervalSince1970))")
                    try? FileManager.default.moveItem(at: auxiliary.appendingPathComponent("index.sqlite3"), to: broken)
                    cache = try? SQLiteCache(url: auxiliary.appendingPathComponent("index.sqlite3"))
                }
            }
            let cached = (try? cache?.cachedNotes()) ?? []
            let cachedByFilename = Dictionary(uniqueKeysWithValues: cached.map { ($0.filename, $0) })
            let scan = try scanner.scan(directory: selectedURL, recognizedExtensions: settings.recognizedExtensions, cached: cachedByFilename)

            self.libraryURL = selectedURL
            self.libraryLock = lock
            self.isReadOnly = !writable
            self.repository = FileRepository(libraryURL: selectedURL)
            self.cache = cache
            self.settingsRepository = settingsRepository
            self.journal = writable ? try RecoveryJournal(directory: auxiliary.appendingPathComponent("journal")) : nil
            self.notes = scan.notes
            self.searchDocuments = Dictionary(uniqueKeysWithValues: scan.notes.map { ($0.id, SearchDocument(note: $0)) })
            self.staleSearchDocumentIDs.removeAll()
            recomputeDuplicateTitleKeys()
            self.baseBodies = Dictionary(uniqueKeysWithValues: scan.notes.map { ($0.id, $0.body) })
            self.undoInvalidationGenerations = [:]
            self.queuedConflicts = [:]
            self.queuedConflictOrder = []
            self.conflict = nil
            self.scanIssues = scan.issues
            selection = []
            selectionKind = .none
            isShowingSelectedNoteTitle = false
            cancelRename()
            searchText = ""
            query = ""
            navigationHistory = []
            listScrollRequest = nil
            if writable, let cache {
                do {
                    try cache.replaceAll(with: scan.notes)
                    cacheIndexedSearchVersions = searchIndexVersions(for: scan.notes)
                } catch {
                    cacheIndexedSearchVersions = [:]
                    logger.error("Unable to refresh search cache: \(String(describing: error), privacy: .public)")
                }
            } else {
                // A read-only cache may have been produced under an older
                // normalization locale or may lag external file changes. With
                // no way to refresh it, treat every current note conservatively.
                cacheIndexedSearchVersions = [:]
            }
            await replayJournal()
            watcher = DirectoryWatcher(url: selectedURL) { [weak self] change in
                Task { @MainActor in await self?.reconcileExternalChanges(change) }
            }
            userDefaults.set(selectedURL.path, forKey: "lastLibraryPath")
            scrollToTopAfterNextSearch = true
            refreshSearch()
            focusSearch()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func select(_ ids: Set<UUID>, explicitly: Bool = true) {
        if explicitly, ids != selection {
            navigationHistory.append((query, selection))
        }
        selection = ids.intersection(Set(results.map(\.id)))
        selectionKind = selection.isEmpty ? .none : (explicitly ? .explicit : .automatic)
        if explicitly { synchronizeSelectedTitlePresentation() }
        populateSelectedHighlightRanges()
    }

    func moveSelection(by offset: Int) {
        guard !results.isEmpty else { return }
        let current = selection.first.flatMap { id in results.firstIndex { $0.id == id } }
        let start = current ?? (offset > 0 ? -1 : results.count)
        let target = min(max(start + offset, 0), results.count - 1)
        select([results[target].id])
        requestListScroll(to: results[target].id, placement: .minimal)
    }

    func userEnteredSearchText(_ value: String) {
        isShowingSelectedNoteTitle = false
        if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            selectionKind = .none
        }
        searchText = value
    }

    func submitSearch() async {
        let parsed = SearchQuery(query)
        let explicitID = selectionKind == .explicit ? selection.first : nil
        let validExplicitID = explicitID.flatMap { id in
            searchDocuments[id].flatMap { SearchService.result(for: $0, query: parsed) } == nil ? nil : id
        }
        let automaticID = SearchService.automaticMatch(
            query: query, documents: Array(searchDocuments.values), sort: sort
        )
        if let id = validExplicitID ?? automaticID {
            select([id], explicitly: true)
            requestListScroll(to: id)
            requestEditorFocus()
        } else if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let title = query.trimmingCharacters(in: .whitespacesAndNewlines)
            await createNote(title: title)
        }
    }

    func clearOrCancel() {
        if isShowingSelectedNoteTitle {
            selection = []
            selectionKind = .none
            isShowingSelectedNoteTitle = false
        }
        searchText = ""
    }

    func deselect() {
        selection = []
        selectionKind = .none
        restoreSearchTextAfterSelection()
    }

    func focusSearch() {
        editorFocusRequest = nil
        focusSearchGeneration += 1
    }

    @discardableResult
    func focusSelectedNoteEditor() -> Bool {
        guard selectedNote != nil else { return false }
        enterSelectedNoteMode()
        requestEditorFocus()
        return true
    }

    func enterSelectedNoteMode() {
        guard selectedNote != nil else { return }
        select(selection, explicitly: true)
    }

    func consumeEditorFocusRequest(_ id: UUID) {
        guard editorFocusRequest?.id == id else { return }
        editorFocusRequest = nil
    }

    func consumeListScrollRequest(_ id: UUID) {
        guard listScrollRequest?.id == id else { return }
        listScrollRequest = nil
    }

    func startRename() {
        guard !isReadOnly, !isRenaming, let note = selectedNote else { return }
        if !showTitleColumn { setNoteListColumn(.title, visible: true) }
        isRenaming = true
        renameRequest = RenameRequest(noteID: note.id)
    }

    func cancelRename() {
        isRenaming = false
        renameRequest = nil
    }

    func updateBody(_ body: String) {
        guard !isReadOnly, let id = selection.first, conflict?.noteID != id,
              let index = notes.firstIndex(where: { $0.id == id }), notes[index].body != body else { return }
        notes[index].body = body
        notes[index].modifiedAt = .now
        notes[index].revision += 1
        staleSearchDocumentIDs.insert(id)
        dirtyNoteIDs.insert(id)
        updateVisibleResult(for: notes[index])
        scheduleJournal(for: notes[index])
        scheduleSave(for: id)
    }

    /// Completes a deferred list refresh when the editor gives up first responder.
    /// Saves and journal writes are scheduled independently and are never delayed by this.
    func finishEditingBurst() {
        guard pendingListResort else { return }
        refreshSearch()
    }

    func updateSelection(_ range: NSRange) {
        guard let id = selection.first, let index = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[index].cursorStart = range.location
        notes[index].cursorLength = range.length
        persistSettingsSoon()
    }

    func deleteSelection() async {
        guard !isReadOnly, !selection.isEmpty else { return }
        if confirmDeletion {
            let alert = NSAlert()
            alert.messageText = selection.count == 1 ? "Move this note to Trash?" : "Move \(selection.count) notes to Trash?"
            alert.informativeText = "The files will be moved to the system Trash."
            alert.addButton(withTitle: "Move to Trash")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() != .alertFirstButtonReturn { return }
        }
        guard let repository else { return }
        let ids = selection
        for id in ids {
            guard notes.contains(where: { $0.id == id }) else { continue }
            guard await flushNoteBeforeDestructiveOperation(id) else { continue }
            guard let note = notes.first(where: { $0.id == id }) else { continue }
            do {
                _ = try await repository.trash(note: note)
                notes.removeAll { $0.id == id }
                searchDocuments[id] = nil
                cacheIndexedSearchVersions[id] = nil
                baseBodies[id] = nil
                dirtyNoteIDs.remove(id)
                pendingLocalWriteHashes[id] = nil
                lastJournaledRevision[id] = nil
                journalIDs[id] = nil
                try? cache?.remove(id: id)
            } catch { errorMessage = error.localizedDescription }
        }
        selection = []
        selectionKind = .none
        restoreSearchTextAfterSelection()
        recomputeDuplicateTitleKeys()
        refreshSearch()
    }

    private func flushNoteBeforeDestructiveOperation(_ id: UUID) async -> Bool {
        let deadlineSave = deadlineTasks.removeValue(forKey: id)
        deadlineSave?.cancel()
        await deadlineSave?.value
        for _ in 0..<4 {
            let scheduledSave = saveTasks.removeValue(forKey: id)
            scheduledSave?.cancel()
            await scheduledSave?.value
            while savingNoteIDs.contains(id) { await Task.yield() }
            guard dirtyNoteIDs.contains(id) else { return true }
            guard conflict?.noteID != id else { return false }
            await save(id)
        }
        return !dirtyNoteIDs.contains(id) && conflict?.noteID != id
    }

    func revealSelectedNote() {
        guard let libraryURL, let note = selectedNote else { return }
        NSWorkspace.shared.activateFileViewerSelecting([libraryURL.appendingPathComponent(note.filename)])
    }

    func performEditorCommand(_ command: EditorCommand) {
        editorCommand = command
        editorCommandGeneration += 1
    }

    func showConflictResolver() {
        if conflict != nil { isConflictPresented = true }
    }

    func deferConflict() {
        isConflictPresented = false
    }

    func openConflictFileExternally() {
        guard let libraryURL, let conflict,
              let note = notes.first(where: { $0.id == conflict.noteID }) else { return }
        NSWorkspace.shared.open(libraryURL.appendingPathComponent(note.filename))
    }

    func navigateBack() {
        while let previous = navigationHistory.popLast() {
            let valid = previous.1.intersection(Set(notes.map(\.id)))
            if !valid.isEmpty || previous.0 != query {
                isShowingSelectedNoteTitle = false
                searchText = previous.0
                selection = valid
                selectionKind = valid.isEmpty ? .none : .explicit
                synchronizeSelectedTitlePresentation()
                return
            }
        }
    }

    func resolveConflictUseFile(expectedConflictID: UUID? = nil) async {
        guard let conflict,
              expectedConflictID == nil || expectedConflictID == conflict.id,
              let index = notes.firstIndex(where: { $0.id == conflict.noteID }) else { return }
        if conflict.fileHash.isEmpty {
            notes.remove(at: index)
            searchDocuments[conflict.noteID] = nil
            staleSearchDocumentIDs.remove(conflict.noteID)
            baseBodies[conflict.noteID] = nil
            cacheIndexedSearchVersions[conflict.noteID] = nil
            try? cache?.remove(id: conflict.noteID)
            selection.remove(conflict.noteID)
            refreshSearch()
            await completeConflictResolution(conflictID: conflict.id, noteID: conflict.noteID)
            return
        }
        notes[index].body = conflict.fileBody
        invalidateUndoHistory(for: conflict.noteID)
        notes[index].lastSavedHash = conflict.fileHash
        notes[index].revision += 1
        searchDocuments[conflict.noteID] = SearchDocument(note: notes[index])
        staleSearchDocumentIDs.remove(conflict.noteID)
        baseBodies[conflict.noteID] = conflict.fileBody
        scheduleCacheUpsert(notes[index])
        refreshSearch()
        await completeConflictResolution(conflictID: conflict.id, noteID: conflict.noteID)
    }

    func resolveConflictKeepApp(expectedConflictID: UUID? = nil) async {
        guard let conflict,
              expectedConflictID == nil || expectedConflictID == conflict.id,
              let note = notes.first(where: { $0.id == conflict.noteID }), let repository else { return }
        let intendedHash = Hashing.sha256(text: note.body, lineEnding: note.lineEnding)
        pendingLocalWriteHashes[conflict.noteID, default: []].insert(intendedHash)
        defer { pendingLocalWriteHashes[conflict.noteID]?.remove(intendedHash) }
        do {
            let result = conflict.fileHash.isEmpty
                ? try await repository.create(
                    filename: note.filename, body: note.body, lineEnding: note.lineEnding
                )
                : try await repository.forceSave(note: note, expectedHash: conflict.fileHash)
            guard self.conflict?.id == conflict.id,
                  let index = notes.firstIndex(where: { $0.id == conflict.noteID }) else { return }
            switch result {
            case .saved(let metadata):
                applyWriteMetadata(metadata, to: &notes[index])
                searchDocuments[conflict.noteID] = SearchDocument(note: notes[index])
                staleSearchDocumentIDs.remove(conflict.noteID)
                baseBodies[conflict.noteID] = notes[index].body
                scheduleCacheUpsert(notes[index])
                await completeConflictResolution(conflictID: conflict.id, noteID: conflict.noteID)
            case .conflict(let data, let hash):
                presentConflict(makeConflict(note: notes[index], data: data, hash: hash))
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func resolveConflictMerge(body: String, expectedConflictID: UUID? = nil) async {
        guard let conflict,
              expectedConflictID == nil || expectedConflictID == conflict.id,
              let index = notes.firstIndex(where: { $0.id == conflict.noteID }) else { return }
        notes[index].body = body
        notes[index].revision += 1
        invalidateUndoHistory(for: conflict.noteID)
        await resolveConflictKeepApp(expectedConflictID: conflict.id)
    }

    func resolveConflictKeepBoth(expectedConflictID: UUID? = nil) async {
        guard let conflict,
              expectedConflictID == nil || expectedConflictID == conflict.id,
              let libraryURL, let repository,
              let appVersion = notes.first(where: { $0.id == conflict.noteID }) else { return }
        do {
            let ext = URL(fileURLWithPath: appVersion.filename).pathExtension
            let stem = try FilenamePolicy.sanitizedStem("\(appVersion.title) App")
            let filename = FilenamePolicy.availableFilename(stem: stem, extension: ext, in: libraryURL)
            guard case .saved(let metadata) = try await repository.create(filename: filename, body: conflict.appBody, lineEnding: appVersion.lineEnding) else { return }
            var copy = Note(
                title: URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent,
                body: conflict.appBody, createdAt: metadata.modifiedAt, modifiedAt: metadata.modifiedAt,
                revision: appVersion.revision + 1, filename: filename,
                lastSavedHash: metadata.hash, lineEnding: appVersion.lineEnding, fileIdentity: metadata.identity
            )
            applyWriteMetadata(metadata, to: &copy)
            guard self.conflict?.id == conflict.id,
                  let index = notes.firstIndex(where: { $0.id == conflict.noteID }) else {
                notes.append(copy)
                searchDocuments[copy.id] = SearchDocument(note: copy)
                baseBodies[copy.id] = copy.body
                scheduleCacheUpsert(copy)
                refreshSearch()
                return
            }
            if conflict.fileHash.isEmpty {
                notes.remove(at: index)
                searchDocuments[appVersion.id] = nil
                staleSearchDocumentIDs.remove(appVersion.id)
                baseBodies[appVersion.id] = nil
                cacheIndexedSearchVersions[appVersion.id] = nil
                try? cache?.remove(id: appVersion.id)
            } else {
                notes[index].body = conflict.fileBody
                invalidateUndoHistory(for: notes[index].id)
                notes[index].lastSavedHash = conflict.fileHash
                notes[index].revision += 1
                searchDocuments[notes[index].id] = SearchDocument(note: notes[index])
                staleSearchDocumentIDs.remove(notes[index].id)
                baseBodies[notes[index].id] = conflict.fileBody
                scheduleCacheUpsert(notes[index])
            }
            notes.append(copy)
            searchDocuments[copy.id] = SearchDocument(note: copy)
            staleSearchDocumentIDs.remove(copy.id)
            recomputeDuplicateTitleKeys()
            baseBodies[copy.id] = copy.body
            scheduleCacheUpsert(copy)
            select([copy.id], explicitly: true)
            refreshSearch()
            await completeConflictResolution(conflictID: conflict.id, noteID: appVersion.id)
        } catch { errorMessage = error.localizedDescription }
    }

    private func completeConflictResolution(conflictID: UUID, noteID: UUID) async {
        saveTasks[noteID]?.cancel()
        saveTasks[noteID] = nil
        deadlineTasks[noteID]?.cancel()
        deadlineTasks[noteID] = nil
        journalTasks[noteID]?.cancel()
        journalTasks[noteID] = nil
        journalDeadlineTasks[noteID]?.cancel()
        journalDeadlineTasks[noteID] = nil

        await journalOperations[noteID]?.value
        guard conflict?.id == conflictID else { return }
        if let journalID = journalIDs[noteID] {
            do { try await journal?.remove(journalID) }
            catch { errorMessage = error.localizedDescription }
            journalIDs[noteID] = Self.journalID(afterRemoving: journalID, current: journalIDs[noteID])
        }
        guard conflict?.id == conflictID else { return }
        journalOperations[noteID] = nil
        journalOperationIDs[noteID] = nil
        dirtyNoteIDs.remove(noteID)
        conflict = takeNextQueuedConflict()
    }

    func flushAll() async throws {
        settingsTask?.cancel()
        for task in journalTasks.values { task.cancel() }
        for task in journalDeadlineTasks.values { task.cancel() }
        journalTasks.removeAll()
        journalDeadlineTasks.removeAll()
        for id in Array(dirtyNoteIDs) { await writeJournalNow(id) }
        for id in Array(dirtyNoteIDs) { _ = await flushNoteBeforeDestructiveOperation(id) }
        if let conflict,
           let note = notes.first(where: { $0.id == conflict.noteID }) {
            throw NVNVError.fileChanged(note.filename)
        }
        if !dirtyNoteIDs.isEmpty {
            let filenames = notes.filter { dirtyNoteIDs.contains($0.id) }.map(\.filename).joined(separator: ", ")
            throw NVNVError.fileOperation(
                path: filenames.isEmpty ? "unsaved notes" : filenames,
                reason: "one or more pending changes could not be saved"
            )
        }
        if let settingsRepository { try await settingsRepository.save(settingsSnapshot()) }
    }

    private func createNote(title: String) async {
        guard !isReadOnly, let libraryURL, let repository else { return }
        do {
            let stem = try FilenamePolicy.sanitizedStem(title)
            let filename = FilenamePolicy.availableFilename(stem: stem, extension: defaultExtension, in: libraryURL)
            guard confirmMaterialTitleChange(input: title, final: URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent) else { return }
            let result = try await repository.create(filename: filename, body: "")
            guard case .saved(let metadata) = result else { return }
            var note = Note(
                title: URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent,
                body: "", createdAt: metadata.modifiedAt, modifiedAt: metadata.modifiedAt,
                filename: filename, lastSavedHash: metadata.hash, fileIdentity: metadata.identity
            )
            applyWriteMetadata(metadata, to: &note)
            notes.append(note)
            searchDocuments[note.id] = SearchDocument(note: note)
            staleSearchDocumentIDs.remove(note.id)
            recomputeDuplicateTitleKeys()
            baseBodies[note.id] = ""
            scheduleCacheUpsert(note)
            let previousQuery = query
            let previousSelection = selection
            navigationHistory.append((previousQuery, previousSelection))
            isShowingSelectedNoteTitle = true
            searchText = note.title
            insertResultForCurrentQuery(note)
            selection = [note.id]
            selectionKind = .explicit
            persistSettingsSoon()
            requestListScroll(to: note.id)
            requestEditorFocus()
        } catch { errorMessage = error.localizedDescription }
    }

    private func requestEditorFocus() {
        guard let noteID = selection.first else { return }
        editorFocusRequest = EditorFocusRequest(noteID: noteID)
    }

    private func requestListScroll(
        to noteID: UUID, placement: ListScrollPlacement = .top
    ) {
        listScrollRequest = ListScrollRequest(noteID: noteID, placement: placement)
    }

    func commitRename(to proposedTitle: String) async {
        guard isRenaming, let request = renameRequest,
              let libraryURL, let repository,
              let note = notes.first(where: { $0.id == request.noteID }),
              let index = notes.firstIndex(where: { $0.id == note.id }) else { return }
        do {
            let stem = try FilenamePolicy.sanitizedStem(proposedTitle)
            let ext = URL(fileURLWithPath: note.filename).pathExtension
            let filename = FilenamePolicy.availableFilename(
                stem: stem, extension: ext, in: libraryURL,
                excluding: libraryURL.appendingPathComponent(note.filename)
            )
            let finalTitle = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
            guard confirmMaterialTitleChange(input: proposedTitle, final: finalTitle) else {
                cancelRename()
                return
            }
            guard finalTitle != note.title else {
                cancelRename()
                return
            }
            _ = try await repository.rename(note: note, to: filename)
            notes[index].filename = filename
            notes[index].title = finalTitle
            notes[index].modifiedAt = .now
            notes[index].revision += 1
            let data = try await repository.data(for: filename)
            notes[index].lastSavedHash = Hashing.sha256(data)
            searchDocuments[note.id] = SearchDocument(note: notes[index])
            staleSearchDocumentIDs.remove(note.id)
            recomputeDuplicateTitleKeys()
            scheduleCacheUpsert(notes[index])
            cancelRename()
            synchronizeSelectedTitlePresentation()
            refreshSearch()
        } catch {
            cancelRename()
            errorMessage = error.localizedDescription
        }
    }

    private func synchronizeSelectedTitlePresentation() {
        guard selectionKind == .explicit, let note = selectedNote else {
            restoreSearchTextAfterSelection()
            return
        }
        isShowingSelectedNoteTitle = true
        if searchText != note.title { searchText = note.title }
    }

    private func restoreSearchTextAfterSelection() {
        guard isShowingSelectedNoteTitle else { return }
        isShowingSelectedNoteTitle = false
        if searchText != query { searchText = query }
    }

    private func confirmMaterialTitleChange(input: String, final: String) -> Bool {
        guard input.trimmingCharacters(in: .whitespacesAndNewlines) != final else { return true }
        let alert = NSAlert()
        alert.messageText = "Use “\(final)” as the note title?"
        alert.informativeText = "The entered title must be adjusted to make a safe, unique filename."
        alert.addButton(withTitle: "Use Title")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func refreshSearch() {
        visibleResultTask?.cancel()
        visibleResultTask = nil
        pendingListResort = false
        searchGeneration += 1
        let generation = searchGeneration
        let query = SearchQuery(query)
        let cachedDocuments = searchDocuments
        let documentsGeneration = searchDocumentsGeneration
        let staleNotes = notes.filter { staleSearchDocumentIDs.contains($0.id) }
        let normalizedTerms = query.terms.map { TextNormalizer.normalize($0.value) }
        let conservativeIDs = Set(notes.compactMap { note in
            cacheIndexedSearchVersions[note.id] == SearchIndexVersion(note) ? nil : note.id
        })
        let cache = cache
        let sort = sort
        // Capturing the result array is O(1) (copy-on-write). Materializing its
        // SearchDocuments used to happen synchronously here, in the TextField
        // setter, which made the second character proportional to the size of
        // the first character's result set.
        let refinementResults: [SearchResult]? = {
            guard staleNotes.isEmpty,
                  lastAppliedSearchDocumentsGeneration == searchDocumentsGeneration,
                  let previousQuery = lastAppliedSearchQuery,
                  SearchService.canIncrementallyRefine(from: previousQuery, to: query) else { return nil }
            return results
        }()
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            let worker = Task.detached(priority: .userInitiated) {
                let candidateIDs: Set<UUID>?
                if refinementResults != nil {
                    candidateIDs = nil
                } else {
                    do {
                        candidateIDs = try cache?.candidateIDs(
                            forNormalizedTerms: normalizedTerms,
                            conservativelyIncluding: conservativeIDs,
                            isCancelled: { Task.isCancelled }
                        )
                    } catch {
                        candidateIDs = nil
                    }
                }
                let candidateCount = refinementResults?.count
                    ?? candidateIDs?.count
                    ?? cachedDocuments.count
                if SearchService.shouldDebounce(candidateCount: candidateCount) {
                    do { try await Task.sleep(for: SearchService.broadSearchStabilizationDelay) }
                    catch { return (found: [SearchResult](), refreshed: [SearchDocument]()) }
                }
                if Task.isCancelled { return (found: [SearchResult](), refreshed: [SearchDocument]()) }

                var documents = cachedDocuments
                var refreshed: [SearchDocument] = []
                refreshed.reserveCapacity(staleNotes.count)
                for note in staleNotes {
                    if Task.isCancelled { return (found: [SearchResult](), refreshed: [SearchDocument]()) }
                    let document = SearchDocument(note: note)
                    documents[note.id] = document
                    refreshed.append(document)
                }
                if Task.isCancelled { return (found: [SearchResult](), refreshed: [SearchDocument]()) }
                let refinementDocuments = refinementResults.flatMap { previousResults -> [SearchDocument]? in
                    let candidates = previousResults.compactMap { documents[$0.id] }
                    return candidates.count == previousResults.count ? candidates : nil
                }
                let candidates = refinementDocuments
                    ?? candidateIDs.map { ids in documents.values.filter { ids.contains($0.id) } }
                    ?? Array(documents.values)
                let found = SearchService.search(
                    query, in: candidates, sort: sort,
                    isCancelled: { Task.isCancelled }
                )
                return (found: found, refreshed: refreshed)
            }
            let output = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled, let self, self.searchGeneration == generation else { return }
            // The worker searched an immutable document snapshot. A note save or
            // external reconciliation can replace documents without changing the
            // query generation; never publish that older snapshot as current.
            guard self.searchDocumentsGeneration == documentsGeneration else {
                self.refreshSearch()
                return
            }
            for document in output.refreshed {
                if self.notes.first(where: { $0.id == document.id })?.revision == document.note.revision {
                    self.searchDocuments[document.id] = document
                    self.staleSearchDocumentIDs.remove(document.id)
                }
            }
            self.lastAppliedSearchDocumentsGeneration = self.searchDocumentsGeneration
            self.lastAppliedSearchQuery = query
            self.applySearchResults(output.found, query: query, sort: sort)
        }
    }

    private func applySearchResults(_ found: [SearchResult], query: SearchQuery, sort: NoteSort) {
        let resolved = selectionKind == .explicit
            ? Self.resultsPreservingMatchingSelection(
                found: found, selection: selection, documents: searchDocuments,
                query: query, sort: sort
            )
            : found
        results = resolved
        let available = Set(resolved.map(\.id))
        if selectionKind == .explicit {
            selection.formIntersection(available)
        } else if let automatic = SearchService.automaticMatch(query: query.rawValue, results: resolved, sort: sort) {
            selection = [automatic]
            selectionKind = .automatic
        } else {
            selection = []
            selectionKind = .none
        }
        synchronizeSelectedTitlePresentation()
        populateSelectedHighlightRanges()
        if scrollToTopAfterNextSearch {
            scrollToTopAfterNextSearch = false
            if let first = resolved.first {
                requestListScroll(to: first.id, placement: .top)
            }
        }
    }

    /// SQLite narrows broad searches to a candidate superset, but its disposable
    /// index can briefly lag a newly-created or externally-reconciled note. The
    /// open note's in-memory document is authoritative, so keep it in the list
    /// whenever it still satisfies the current query.
    static func resultsPreservingMatchingSelection(
        found: [SearchResult], selection: Set<UUID>,
        documents: [UUID: SearchDocument], query: SearchQuery, sort: NoteSort
    ) -> [SearchResult] {
        var resolved = found
        let available = Set(found.map(\.id))
        var insertedMatch = false
        for id in selection.subtracting(available) {
            guard let document = documents[id],
                  let result = SearchService.result(for: document, query: query) else { continue }
            resolved.append(result)
            insertedMatch = true
        }
        guard insertedMatch else { return found }
        return resolved.sorted { SearchService.compare($0.note, $1.note, sort: sort) }
    }

    private func populateSelectedHighlightRanges() {
        guard highlightSearch, selection.count == 1, let id = selection.first,
              let document = searchDocuments[id],
              let highlighted = SearchService.result(for: document, query: SearchQuery(query)),
              let index = results.firstIndex(where: { $0.id == id }) else { return }
        results[index] = highlighted
    }

    private func insertResultForCurrentQuery(_ note: Note) {
        searchGeneration += 1
        searchTask?.cancel()
        var updated = results.filter { $0.id != note.id }
        if let document = searchDocuments[note.id],
           let result = SearchService.result(for: document, query: SearchQuery(query)) {
            updated.append(result)
        }
        results = updated.sorted { SearchService.compare($0.note, $1.note, sort: sort) }
        refreshSearch()
    }

    private func updateVisibleResult(for note: Note) {
        // Invalidate any in-flight search built from an older revision. Updating
        // one visible value is cheap and, importantly, preserves its list index
        // while the user is typing even when sorting by modification date.
        searchGeneration += 1
        searchTask?.cancel()
        if let index = results.firstIndex(where: { $0.id == note.id }) {
            let old = results[index]
            results[index] = SearchResult(
                note: note, titleRanges: old.titleRanges, bodyRanges: []
            )
        }

        // Re-evaluate membership and sorting once the typing burst goes idle.
        // The editor's focus-loss callback flushes this immediately when needed.
        pendingListResort = true
        visibleResultTask?.cancel()
        visibleResultTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(650)) }
            catch { return }
            guard !Task.isCancelled else { return }
            self?.refreshSearch()
        }
    }

    private func recomputeDuplicateTitleKeys() {
        let grouped = Dictionary(grouping: notes, by: { TextNormalizer.normalize($0.title) })
        duplicateTitleKeys = Set(grouped.filter { $0.value.count > 1 }.map(\.key))
    }

    private func scheduleCacheUpsert(_ note: Note) {
        guard let cache else { return }
        let version = SearchIndexVersion(note)
        Task { [weak self] in
            let succeeded = await Task.detached(priority: .utility) {
                do {
                    try cache.upsert(note)
                    return true
                } catch {
                    return false
                }
            }.value
            guard succeeded, let self, self.cache === cache,
                  let current = self.notes.first(where: { $0.id == note.id }),
                  SearchIndexVersion(current) == version else { return }
            self.cacheIndexedSearchVersions[note.id] = version
        }
    }

    private func scheduleCacheChanges(upserting notes: [Note], removing ids: Set<UUID>) {
        guard let cache, !notes.isEmpty || !ids.isEmpty else { return }
        let versions = searchIndexVersions(for: notes)
        Task { [weak self] in
            let succeeded = await Task.detached(priority: .utility) {
                do {
                    try cache.applyChanges(upserting: notes, removing: ids)
                    return true
                } catch {
                    return false
                }
            }.value
            guard succeeded, let self, self.cache === cache else { return }
            for id in ids where !self.notes.contains(where: { $0.id == id }) {
                self.cacheIndexedSearchVersions.removeValue(forKey: id)
            }
            for note in notes {
                let version = versions[note.id]
                guard let version,
                      let current = self.notes.first(where: { $0.id == note.id }),
                      SearchIndexVersion(current) == version else { continue }
                self.cacheIndexedSearchVersions[note.id] = version
            }
        }
    }

    private func searchIndexVersions(for notes: [Note]) -> [UUID: SearchIndexVersion] {
        Dictionary(uniqueKeysWithValues: notes.map { ($0.id, SearchIndexVersion($0)) })
    }

    /// Updates only search state whose authoritative note changed. Metadata-only
    /// changes reuse normalized body/title storage; content changes rebuild one
    /// document. The caller retains responsibility for a full scan when needed.
    private func applyExternalSearchChanges(from previous: [Note], to current: [Note]) {
        let previousByID = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
        let currentIDs = Set(current.map(\.id))
        let removedIDs = Set(previousByID.keys).subtracting(currentIDs)
        let changedNotes = current.filter { previousByID[$0.id] != $0 }

        applyExternalSearchChanges(upserting: changedNotes, removing: removedIDs, previousByID: previousByID)
    }

    private func applyExternalSearchChanges(
        upserting changedNotes: [Note], removing removedIDs: Set<UUID>,
        previousByID: [UUID: Note]
    ) {
        for id in removedIDs {
            searchDocuments.removeValue(forKey: id)
            staleSearchDocumentIDs.remove(id)
        }
        for note in changedNotes {
            if let old = previousByID[note.id], old.title == note.title, old.body == note.body,
               let document = searchDocuments[note.id] {
                searchDocuments[note.id] = document.replacingMetadata(with: note)
            } else {
                searchDocuments[note.id] = SearchDocument(note: note)
            }
            staleSearchDocumentIDs.remove(note.id)
        }

        if !isReadOnly {
            scheduleCacheChanges(upserting: changedNotes, removing: removedIDs)
        }
    }

    private func scheduleJournal(for note: Note) {
        guard journal != nil else { return }
        journalTasks[note.id]?.cancel()
        journalTasks[note.id] = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(400)) }
            catch { return }
            guard !Task.isCancelled else { return }
            await self?.writeJournalNow(note.id)
        }
        if journalDeadlineTasks[note.id] == nil {
            journalDeadlineTasks[note.id] = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(2)) }
                catch { return }
                guard !Task.isCancelled else { return }
                await self?.writeJournalNow(note.id)
            }
        }
    }

    private func writeJournalNow(_ id: UUID) async {
        guard let journal, let note = notes.first(where: { $0.id == id }),
              (lastJournaledRevision[id] ?? -1) < note.revision else { return }
        journalTasks[id]?.cancel()
        journalTasks[id] = nil
        journalDeadlineTasks[id]?.cancel()
        journalDeadlineTasks[id] = nil

        let preceding = journalOperations[id]
        let operationID = UUID()
        journalOperationIDs[id] = operationID
        let operation = Task { [weak self] in
            await preceding?.value
            guard let self else { return }
            await self.performJournalWrite(note, journal: journal)
        }
        journalOperations[id] = operation
        await operation.value
        if journalOperationIDs[id] == operationID {
            journalOperations[id] = nil
            journalOperationIDs[id] = nil
        }
        if let current = notes.first(where: { $0.id == id }), current.revision > note.revision {
            scheduleJournal(for: current)
        }
    }

    private func performJournalWrite(_ note: Note, journal: RecoveryJournal) async {
        guard (lastJournaledRevision[note.id] ?? -1) < note.revision else { return }
        let previous = journalIDs[note.id]
        let entry = JournalEntry(
            noteID: note.id, kind: .edit, baseHash: note.lastSavedHash,
            filename: note.filename, intendedFilename: note.filename,
            body: note.body, revision: note.revision
        )
        do {
            try await journal.record(entry)
            journalIDs[note.id] = entry.id
            lastJournaledRevision[note.id] = note.revision
            if let previous { try? await journal.remove(previous) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func scheduleSave(for id: UUID) {
        saveTasks[id]?.cancel()
        saveTasks[id] = Task {
            try? await Task.sleep(for: .milliseconds(750))
            guard !Task.isCancelled else { return }
            await save(id)
        }
        if deadlineTasks[id] == nil {
            deadlineTasks[id] = Task {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                await save(id)
            }
        }
    }

    private func save(_ id: UUID) async {
        guard dirtyNoteIDs.contains(id), !savingNoteIDs.contains(id), let repository else { return }
        savingNoteIDs.insert(id)
        defer { savingNoteIDs.remove(id) }
        await writeJournalNow(id)
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        let snapshot = notes[index]
        let intendedHash = Hashing.sha256(text: snapshot.body, lineEnding: snapshot.lineEnding)
        pendingLocalWriteHashes[id, default: []].insert(intendedHash)
        defer { pendingLocalWriteHashes[id]?.remove(intendedHash) }
        do {
            switch try await repository.save(note: snapshot) {
            case .saved(let metadata):
                guard let current = notes.firstIndex(where: { $0.id == id }) else { return }
                if notes[current].revision == snapshot.revision {
                    dirtyNoteIDs.remove(id)
                    saveTasks[id] = nil
                    deadlineTasks[id]?.cancel()
                    deadlineTasks[id] = nil
                } else {
                    notes[current].lastSavedHash = metadata.hash
                    scheduleSave(for: id)
                }
                applyWriteMetadata(metadata, to: &notes[current])
                if let document = searchDocuments[id] {
                    searchDocuments[id] = document.replacingMetadata(with: notes[current])
                }
                baseBodies[id] = snapshot.body
                if let journalID = journalIDs[id], notes[current].revision == snapshot.revision {
                    try? await journal?.remove(journalID)
                    journalIDs[id] = Self.journalID(afterRemoving: journalID, current: journalIDs[id])
                }
                scheduleCacheUpsert(notes[current])
            case .conflict(let data, let hash):
                guard let current = notes.first(where: { $0.id == id }) else { return }
                presentConflict(makeConflict(note: current, data: data, hash: hash))
            }
        } catch { errorMessage = error.localizedDescription }
    }

    private func makeConflict(note: Note, data: Data, hash: String) -> Conflict {
        let raw = String(data: data, encoding: .utf8) ?? ""
        let fileBody = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return Conflict(
            noteID: note.id, baseBody: baseBodies[note.id] ?? "",
            appBody: note.body, fileBody: fileBody, fileHash: hash
        )
    }

    static func journalID(afterRemoving removed: UUID, current: UUID?) -> UUID? {
        current == removed ? nil : current
    }

    private func invalidateUndoHistory(for noteID: UUID) {
        undoInvalidationGenerations[noteID, default: 0] &+= 1
    }

    func presentConflict(_ newConflict: Conflict) {
        guard let active = conflict else {
            conflict = newConflict
            return
        }
        if active.noteID == newConflict.noteID {
            conflict = newConflict
            return
        }
        if queuedConflicts[newConflict.noteID] == nil {
            queuedConflictOrder.append(newConflict.noteID)
        }
        queuedConflicts[newConflict.noteID] = newConflict
    }

    private func takeNextQueuedConflict() -> Conflict? {
        while !queuedConflictOrder.isEmpty {
            let noteID = queuedConflictOrder.removeFirst()
            if let next = queuedConflicts.removeValue(forKey: noteID) { return next }
        }
        return nil
    }

    private func applyWriteMetadata(_ metadata: FileWriteMetadata, to note: inout Note) {
        note.lastSavedHash = metadata.hash
        note.modifiedAt = metadata.modifiedAt
        note.fileIdentity = metadata.identity
        note.fileSize = metadata.fileSize
        note.fileModificationSeconds = metadata.modificationSeconds
        note.fileModificationNanoseconds = metadata.modificationNanoseconds
        note.fileStatusChangeSeconds = metadata.statusChangeSeconds
        note.fileStatusChangeNanoseconds = metadata.statusChangeNanoseconds
    }

    private func acknowledgingSavedFile(_ disk: Note, whilePreserving app: Note) -> Note {
        var acknowledged = app
        acknowledged.title = disk.title
        acknowledged.filename = disk.filename
        acknowledged.modifiedAt = disk.modifiedAt
        acknowledged.lastSavedHash = disk.lastSavedHash
        acknowledged.lineEnding = disk.lineEnding
        acknowledged.fileIdentity = disk.fileIdentity
        acknowledged.fileSize = disk.fileSize
        acknowledged.fileModificationSeconds = disk.fileModificationSeconds
        acknowledged.fileModificationNanoseconds = disk.fileModificationNanoseconds
        acknowledged.fileStatusChangeSeconds = disk.fileStatusChangeSeconds
        acknowledged.fileStatusChangeNanoseconds = disk.fileStatusChangeNanoseconds
        acknowledged.revision = max(app.revision, disk.revision)
        return acknowledged
    }

    private func reconcileExternalChanges(_ change: DirectoryWatcher.Change) async {
        guard let libraryURL else { return }
        if !change.requiresFullRescan {
            await reconcileTargetedExternalChanges(paths: change.paths, libraryURL: libraryURL)
            return
        }
        reconcileGeneration += 1
        let generation = reconcileGeneration
        let scanner = scanner
        let extensions = recognizedExtensions
        let cachedNotes = notes
        do {
            let oldByFilename = Dictionary(uniqueKeysWithValues: cachedNotes.map { ($0.filename, $0) })
            var scan = try await Task.detached(priority: .utility) {
                try scanner.scan(directory: libraryURL, recognizedExtensions: extensions, cached: oldByFilename)
            }.value
            guard generation == reconcileGeneration else { return }
            let currentByID = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, $0) })
            let oldByID = Dictionary(uniqueKeysWithValues: cachedNotes.map { ($0.id, $0) })
            let oldByIdentity = Dictionary(uniqueKeysWithValues: cachedNotes.compactMap { note in note.fileIdentity.map { ($0, note) } })
            let identityPreserved = scan.notes.map { disk -> Note in
                guard oldByFilename[disk.filename] == nil, let identity = disk.fileIdentity,
                      let old = oldByIdentity[identity] else { return disk }
                var renamed = disk
                renamed = Note(
                    id: old.id, title: disk.title, body: disk.body,
                    createdAt: old.createdAt, modifiedAt: disk.modifiedAt,
                    cursorStart: old.cursorStart, cursorLength: old.cursorLength,
                    revision: old.revision + 1, filename: disk.filename,
                    lastSavedHash: disk.lastSavedHash, lineEnding: disk.lineEnding,
                    fileIdentity: disk.fileIdentity, fileSize: disk.fileSize,
                    fileModificationSeconds: disk.fileModificationSeconds,
                    fileModificationNanoseconds: disk.fileModificationNanoseconds,
                    fileStatusChangeSeconds: disk.fileStatusChangeSeconds,
                    fileStatusChangeNanoseconds: disk.fileStatusChangeNanoseconds
                )
                return renamed
            }
            scan = ScanResult(notes: identityPreserved, issues: scan.issues)
            var reconciled: [Note] = []
            var handledNoteIDs: Set<UUID> = []
            for disk in scan.notes {
                guard let old = oldByFilename[disk.filename] ?? oldByID[disk.id] else {
                    reconciled.append(disk)
                    continue
                }
                handledNoteIDs.insert(old.id)
                let app = currentByID[old.id] ?? old
                let disposition = FileChangeClassifier.classify(
                    diskHash: disk.lastSavedHash, lastSavedHash: app.lastSavedHash,
                    diskBody: disk.body, appBody: app.body,
                    isDirty: dirtyNoteIDs.contains(app.id),
                    pendingLocalWriteHashes: pendingLocalWriteHashes[app.id] ?? []
                )
                switch disposition {
                case .unchanged:
                    reconciled.append(acknowledgingSavedFile(disk, whilePreserving: app))
                case .localWrite, .identicalContent:
                    reconciled.append(acknowledgingSavedFile(disk, whilePreserving: app))
                    baseBodies[app.id] = disk.body
                case .conflict:
                    presentConflict(Conflict(
                        noteID: app.id, baseBody: baseBodies[app.id] ?? "",
                        appBody: app.body, fileBody: disk.body, fileHash: disk.lastSavedHash
                    ))
                    reconciled.append(app)
                case .external:
                    reconciled.append(disk)
                    invalidateUndoHistory(for: disk.id)
                    baseBodies[disk.id] = disk.body
                    transientMessage = "“\(disk.title)” changed outside nvnv. Its undo history was cleared."
                }
            }
            let scannedFilenames = Set(scan.notes.map(\.filename))
            for app in notes where !scannedFilenames.contains(app.filename)
                && !handledNoteIDs.contains(app.id) {
                if dirtyNoteIDs.contains(app.id) {
                    presentConflict(Conflict(noteID: app.id, baseBody: baseBodies[app.id] ?? "", appBody: app.body, fileBody: "", fileHash: ""))
                    reconciled.append(app)
                }
            }
            notes = reconciled
            applyExternalSearchChanges(from: cachedNotes, to: reconciled)
            recomputeDuplicateTitleKeys()
            scanIssues = scan.issues
            refreshSearch()
        } catch { errorMessage = error.localizedDescription }
    }

    private func reconcileTargetedExternalChanges(paths: Set<URL>, libraryURL: URL) async {
        reconcileGeneration += 1
        let generation = reconcileGeneration
        let scanner = scanner
        let extensions = recognizedExtensions
        let cachedNotes = notes
        let oldByFilename = Dictionary(uniqueKeysWithValues: cachedNotes.map { ($0.filename, $0) })
        let oldByID = Dictionary(uniqueKeysWithValues: cachedNotes.map { ($0.id, $0) })
        let oldByIdentity = Dictionary(uniqueKeysWithValues: cachedNotes.compactMap { note in
            note.fileIdentity.map { ($0, note) }
        })
        let root = libraryURL.standardizedFileURL
        let relevantPaths = Set(paths.map(\.standardizedFileURL).filter { url in
            guard url.deletingLastPathComponent() == root, !url.lastPathComponent.hasPrefix(".") else { return false }
            return oldByFilename[url.lastPathComponent] != nil
                || extensions.contains(url.pathExtension.lowercased())
        })
        guard !relevantPaths.isEmpty else { return }
        do {
            let scan = try await Task.detached(priority: .utility) {
                try scanner.scan(
                    directory: libraryURL, paths: relevantPaths,
                    recognizedExtensions: extensions, cached: oldByFilename
                )
            }.value
            guard generation == reconcileGeneration else { return }
            let currentByID = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, $0) })

            let affectedFilenames = Set(relevantPaths.map(\.lastPathComponent))
            var upsertsByID: [UUID: Note] = [:]
            var handledOldIDs: Set<UUID> = []
            for var disk in scan.notes {
                let old = oldByFilename[disk.filename]
                    ?? disk.fileIdentity.flatMap { oldByIdentity[$0] }
                guard let old else {
                    upsertsByID[disk.id] = disk
                    continue
                }
                handledOldIDs.insert(old.id)
                if disk.filename != old.filename {
                    disk = Note(
                        id: old.id, title: disk.title, body: disk.body,
                        createdAt: old.createdAt, modifiedAt: disk.modifiedAt,
                        cursorStart: old.cursorStart, cursorLength: old.cursorLength,
                        revision: old.revision + 1, filename: disk.filename,
                        lastSavedHash: disk.lastSavedHash, lineEnding: disk.lineEnding,
                        fileIdentity: disk.fileIdentity, fileSize: disk.fileSize,
                        fileModificationSeconds: disk.fileModificationSeconds,
                        fileModificationNanoseconds: disk.fileModificationNanoseconds,
                        fileStatusChangeSeconds: disk.fileStatusChangeSeconds,
                        fileStatusChangeNanoseconds: disk.fileStatusChangeNanoseconds
                    )
                }
                let app = currentByID[old.id] ?? old
                let disposition = FileChangeClassifier.classify(
                    diskHash: disk.lastSavedHash, lastSavedHash: app.lastSavedHash,
                    diskBody: disk.body, appBody: app.body,
                    isDirty: dirtyNoteIDs.contains(app.id),
                    pendingLocalWriteHashes: pendingLocalWriteHashes[app.id] ?? []
                )
                switch disposition {
                case .unchanged:
                    // Preserve current text while recording the newest file
                    // fingerprint from a metadata-only event.
                    upsertsByID[app.id] = acknowledgingSavedFile(disk, whilePreserving: app)
                case .localWrite, .identicalContent:
                    upsertsByID[app.id] = acknowledgingSavedFile(disk, whilePreserving: app)
                    baseBodies[app.id] = disk.body
                case .conflict:
                    presentConflict(Conflict(
                        noteID: app.id, baseBody: baseBodies[app.id] ?? "", appBody: app.body,
                        fileBody: disk.body, fileHash: disk.lastSavedHash
                    ))
                    upsertsByID[app.id] = app
                case .external:
                    upsertsByID[app.id] = disk
                    invalidateUndoHistory(for: app.id)
                    baseBodies[app.id] = disk.body
                    transientMessage = "“\(disk.title)” changed outside nvnv. Its undo history was cleared."
                }
            }

            var removedIDs: Set<UUID> = []
            for old in cachedNotes where affectedFilenames.contains(old.filename)
                && !handledOldIDs.contains(old.id) {
                let app = currentByID[old.id] ?? old
                if dirtyNoteIDs.contains(app.id) {
                    presentConflict(Conflict(
                        noteID: app.id, baseBody: baseBodies[app.id] ?? "", appBody: app.body,
                        fileBody: "", fileHash: ""
                    ))
                    upsertsByID[app.id] = app
                } else {
                    removedIDs.insert(app.id)
                }
            }

            let actualUpserts = upsertsByID.values.filter { oldByID[$0.id] != $0 }
            var reconciled = notes.filter { !removedIDs.contains($0.id) }
            var indices = Dictionary(uniqueKeysWithValues: reconciled.enumerated().map { ($0.element.id, $0.offset) })
            for note in actualUpserts {
                if let index = indices[note.id] {
                    reconciled[index] = note
                } else {
                    indices[note.id] = reconciled.count
                    reconciled.append(note)
                }
            }
            notes = reconciled
            applyExternalSearchChanges(
                upserting: Array(actualUpserts), removing: removedIDs, previousByID: oldByID
            )
            recomputeDuplicateTitleKeys()
            scanIssues.removeAll { affectedFilenames.contains($0.filename) }
            scanIssues.append(contentsOf: scan.issues)
            refreshSearch()
        } catch { errorMessage = error.localizedDescription }
    }

    private func replayJournal() async {
        guard let journal, let repository else { return }
        do {
            for entry in try await journal.pending() {
                guard entry.kind == .edit || entry.kind == .create else { continue }
                if let index = notes.firstIndex(where: { $0.id == entry.noteID || $0.filename == entry.filename }) {
                    if notes[index].lastSavedHash == entry.baseHash {
                        notes[index].body = entry.body
                        notes[index].revision = max(notes[index].revision, entry.revision)
                        switch try await repository.save(note: notes[index]) {
                        case .saved(let metadata):
                            applyWriteMetadata(metadata, to: &notes[index])
                            baseBodies[notes[index].id] = notes[index].body
                            try await journal.remove(entry.id)
                            transientMessage = "Recovered “\(notes[index].title)” after an interrupted save."
                        case .conflict(let data, let hash):
                            presentConflict(makeConflict(note: notes[index], data: data, hash: hash))
                        }
                    } else {
                        notes[index].body = entry.body
                        presentConflict(makeConflict(note: notes[index], data: try await repository.data(for: entry.filename), hash: notes[index].lastSavedHash))
                    }
                }
            }
            searchDocuments = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, SearchDocument(note: $0)) })
            staleSearchDocumentIDs.removeAll()
            recomputeDuplicateTitleKeys()
        } catch { errorMessage = error.localizedDescription }
    }

    private func apply(_ settings: LibrarySettings) {
        sort = settings.sort
        dividerFraction = settings.dividerFraction
        showTitleColumn = settings.showTitleColumn ?? true
        showModifiedDate = settings.showModifiedDate
        showCreatedDate = settings.showCreatedDate
        noteListColumnOrder = Self.normalizedNoteListColumnOrder(settings.noteListColumnOrder)
        if visibleNoteListColumns.isEmpty { showTitleColumn = true }
        showExcerpts = settings.showExcerpts
        confirmDeletion = settings.confirmDeletion
        highlightSearch = settings.highlightSearch
        editorFontName = settings.editorFontName
        // Version 2 and earlier shipped with 14 pt as the default editor size.
        // Migrate only that exact default and preserve deliberate custom sizes.
        let storedEditorFontSize = settings.schemaVersion < 3 && settings.editorFontSize == 14
            ? 12
            : settings.editorFontSize
        editorFontSize = min(max(storedEditorFontSize, 10), 14)
        softTabs = settings.softTabs
        tabWidth = settings.tabWidth
        tabIndents = settings.tabIndents
        extensionList = settings.recognizedExtensions.sorted().joined(separator: ", ")
        defaultExtension = settings.defaultExtension
    }

    private func settingsSnapshot() -> LibrarySettings {
        var settings = LibrarySettings()
        // Search, selection, and list position are intentionally session-only.
        // Keep writing empty legacy fields so older settings files converge to
        // the fresh-launch behavior without requiring a schema migration.
        settings.query = ""
        settings.selectedNoteIDs = []
        settings.selectionKind = .none
        settings.sort = sort
        settings.dividerFraction = dividerFraction
        settings.showTitleColumn = showTitleColumn
        settings.showModifiedDate = showModifiedDate
        settings.showCreatedDate = showCreatedDate
        settings.noteListColumnOrder = noteListColumnOrder
        settings.showExcerpts = showExcerpts
        settings.confirmDeletion = confirmDeletion
        settings.highlightSearch = highlightSearch
        settings.listFontSize = 11
        settings.editorFontName = editorFontName
        settings.editorFontSize = editorFontSize
        settings.softTabs = softTabs
        settings.tabWidth = tabWidth
        settings.tabIndents = tabIndents
        settings.recognizedExtensions = recognizedExtensions
        settings.defaultExtension = defaultExtension
        return settings
    }

    static func normalizedNoteListColumnOrder(_ stored: [NoteListColumn]?) -> [NoteListColumn] {
        var normalized: [NoteListColumn] = []
        for column in (stored ?? []) + NoteListColumn.allCases where !normalized.contains(column) {
            normalized.append(column)
        }
        return normalized
    }

    private func persistSettingsSoon() {
        settingsTask?.cancel()
        settingsTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let settingsRepository else { return }
            try? await settingsRepository.save(settingsSnapshot())
        }
    }
}

extension NoteListColumn {
    var title: String {
        switch self {
        case .title: "Title"
        case .modified: "Date Modified"
        case .created: "Date Created"
        }
    }

    var sortField: NoteSortField {
        switch self {
        case .title: .title
        case .modified: .modified
        case .created: .created
        }
    }
}

private struct SearchIndexVersion: Equatable, Sendable {
    let revision: Int
    let lastSavedHash: String
    let title: String

    init(_ note: Note) {
        revision = note.revision
        lastSavedHash = note.lastSavedHash
        title = note.title
    }
}

enum EditorCommand {
    case indent
    case outdent
    case find
    case findNext
    case findPrevious
    case openURL
}

struct EditorFocusRequest: Equatable {
    let id = UUID()
    let noteID: UUID
}

struct ListScrollRequest: Equatable {
    let id = UUID()
    let noteID: UUID
    let placement: ListScrollPlacement
}

struct RenameRequest: Equatable {
    let id = UUID()
    let noteID: UUID
}

enum ListScrollPlacement: Equatable {
    case minimal
    case top
}
