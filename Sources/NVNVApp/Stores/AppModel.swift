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
        didSet { if !isRenaming { query = searchText } }
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
        didSet { if conflict != nil { isConflictPresented = true } }
    }
    var isConflictPresented = false
    var isRenaming = false
    var focusSearchGeneration = 0
    var editorFocusRequest: EditorFocusRequest?
    var listScrollRequest: ListScrollRequest?
    var dividerFraction = 0.36 { didSet { persistSettingsSoon() } }
    var showModifiedDate = true { didSet { persistSettingsSoon() } }
    var showCreatedDate = false { didSet { persistSettingsSoon() } }
    var showExcerpts = true { didSet { persistSettingsSoon() } }
    var confirmDeletion = true { didSet { persistSettingsSoon() } }
    var highlightSearch = true { didSet { persistSettingsSoon() } }
    var listFontSize = 11.0 { didSet { persistSettingsSoon() } }
    var editorFontName = "" { didSet { persistSettingsSoon() } }
    var editorFontSize = 12.0 { didSet { persistSettingsSoon() } }
    var softTabs = false { didSet { persistSettingsSoon() } }
    var tabWidth = 4 { didSet { persistSettingsSoon() } }
    var tabIndents = true { didSet { persistSettingsSoon() } }
    var extensionList = "txt" { didSet { persistSettingsSoon() } }
    var defaultExtension = "txt" { didSet { persistSettingsSoon() } }
    var editorCommand: EditorCommand?
    var editorCommandGeneration = 0
    private(set) var duplicateTitleKeys: Set<String> = []

    private let logger = Logger(subsystem: "app.nvnv", category: "library")
    private let scanner = LibraryScanner()
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
    private var journalTasks: [UUID: Task<Void, Never>] = [:]
    private var journalDeadlineTasks: [UUID: Task<Void, Never>] = [:]
    private var journalOperations: [UUID: Task<Void, Never>] = [:]
    private var journalOperationIDs: [UUID: UUID] = [:]
    private var lastJournaledRevision: [UUID: Int] = [:]
    private var journalIDs: [UUID: UUID] = [:]
    private var baseBodies: [UUID: String] = [:]
    private var dirtyNoteIDs: Set<UUID> = []
    private var renameOriginalQuery = ""
    private var priorExplicitQuery: String?
    private var settingsTask: Task<Void, Never>?
    private var pendingListResort = false
    private var scrollToTopAfterNextSearch = false
    private var navigationHistory: [(String, Set<UUID>)] = []

    init(userDefaults: UserDefaults = .standard) {
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

    var recognizedExtensions: Set<String> {
        let parsed = extensionList.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        }.filter { !$0.isEmpty }
        return Set(parsed).union([defaultExtension.lowercased()])
    }

    func restoreLastLibrary() async {
        guard libraryURL == nil else {
            isRestoringLibrary = false
            return
        }
        guard let path = UserDefaults.standard.string(forKey: "lastLibraryPath") else {
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
        lastJournaledRevision = [:]
        journalIDs = [:]
        journalOperations = [:]
        journalOperationIDs = [:]
        duplicateTitleKeys = []
        navigationHistory = []
        priorExplicitQuery = nil
        scanIssues = []
        conflict = nil
        isConflictPresented = false
        isReadOnly = false
        isIndexing = false
        isRenaming = false
        editorFocusRequest = nil
        listScrollRequest = nil
        errorMessage = nil
        transientMessage = nil
        UserDefaults.standard.removeObject(forKey: "lastLibraryPath")
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
        searchText = defaults.query
        query = defaults.query
        selection = defaults.selectedNoteIDs
        selectionKind = defaults.selectionKind
        navigationHistory = []
        UserDefaults.standard.removeObject(forKey: "noteListModifiedDateColumnWidth")
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
            self.scanIssues = scan.issues
            selection = []
            selectionKind = .none
            searchText = ""
            query = ""
            navigationHistory = []
            priorExplicitQuery = nil
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
            UserDefaults.standard.set(selectedURL.path, forKey: "lastLibraryPath")
            if !writable { errorMessage = NVNVError.locked.localizedDescription }
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
            priorExplicitQuery = query
        }
        selection = ids.intersection(Set(results.map(\.id)))
        selectionKind = selection.isEmpty ? .none : (explicitly ? .explicit : .automatic)
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
        if !isRenaming, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            selectionKind = .none
        }
        searchText = value
    }

    func submitSearch() async {
        if isRenaming { await commitRename(); return }
        let parsed = SearchQuery(query)
        let explicitID = selectionKind == .explicit ? selection.first : nil
        let validExplicitID = explicitID.flatMap { id in
            searchDocuments[id].flatMap { SearchService.result(for: $0, query: parsed) } == nil ? nil : id
        }
        let automaticID = SearchService.automaticMatch(
            query: query, documents: Array(searchDocuments.values), sort: sort
        )
        if let id = validExplicitID ?? automaticID {
            if selection != [id] { select([id], explicitly: true) }
            requestListScroll(to: id)
            requestEditorFocus()
        } else if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let title = query.trimmingCharacters(in: .whitespacesAndNewlines)
            await createNote(title: title)
        }
    }

    func clearOrCancel() {
        if isRenaming {
            isRenaming = false
            searchText = renameOriginalQuery
            query = renameOriginalQuery
        } else {
            searchText = ""
        }
    }

    func deselect() {
        selection = []
        selectionKind = .none
        if let priorExplicitQuery { searchText = priorExplicitQuery }
    }

    func focusSearch() {
        editorFocusRequest = nil
        focusSearchGeneration += 1
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
        guard !isReadOnly, let note = selectedNote else { return }
        renameOriginalQuery = query
        isRenaming = true
        searchText = note.title
        focusSearch()
    }

    func updateBody(_ body: String) {
        guard !isReadOnly, conflict == nil, let id = selection.first,
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
            guard let note = notes.first(where: { $0.id == id }) else { continue }
            do {
                _ = try await repository.trash(note: note)
                notes.removeAll { $0.id == id }
                searchDocuments[id] = nil
                cacheIndexedSearchVersions[id] = nil
                try? cache?.remove(id: id)
            } catch { errorMessage = error.localizedDescription }
        }
        selection = []
        recomputeDuplicateTitleKeys()
        refreshSearch()
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
        guard let libraryURL, let note = selectedNote else { return }
        NSWorkspace.shared.open(libraryURL.appendingPathComponent(note.filename))
    }

    func navigateBack() {
        while let previous = navigationHistory.popLast() {
            let valid = previous.1.intersection(Set(notes.map(\.id)))
            if !valid.isEmpty || previous.0 != query {
                searchText = previous.0
                selection = valid
                selectionKind = valid.isEmpty ? .none : .explicit
                return
            }
        }
    }

    func resolveConflictUseFile() {
        guard let conflict, let index = notes.firstIndex(where: { $0.id == conflict.noteID }) else { return }
        notes[index].body = conflict.fileBody
        notes[index].lastSavedHash = conflict.fileHash
        notes[index].revision += 1
        searchDocuments[conflict.noteID] = SearchDocument(note: notes[index])
        staleSearchDocumentIDs.remove(conflict.noteID)
        baseBodies[conflict.noteID] = conflict.fileBody
        dirtyNoteIDs.remove(conflict.noteID)
        self.conflict = nil
        scheduleCacheUpsert(notes[index])
        refreshSearch()
    }

    func resolveConflictKeepApp() async {
        guard let conflict, let index = notes.firstIndex(where: { $0.id == conflict.noteID }), let repository else { return }
        do {
            let result = try await repository.forceSave(note: notes[index], expectedHash: conflict.fileHash)
            switch result {
            case .saved(let hash, let date, let identity):
                notes[index].lastSavedHash = hash
                notes[index].modifiedAt = date
                notes[index].fileIdentity = identity
                searchDocuments[conflict.noteID] = SearchDocument(note: notes[index])
                staleSearchDocumentIDs.remove(conflict.noteID)
                baseBodies[conflict.noteID] = notes[index].body
                dirtyNoteIDs.remove(conflict.noteID)
                self.conflict = nil
                scheduleCacheUpsert(notes[index])
            case .conflict(let data, let hash):
                self.conflict = makeConflict(note: notes[index], data: data, hash: hash)
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func resolveConflictMerge(body: String) async {
        guard let conflict, let index = notes.firstIndex(where: { $0.id == conflict.noteID }) else { return }
        notes[index].body = body
        notes[index].revision += 1
        await resolveConflictKeepApp()
    }

    func resolveConflictKeepBoth() async {
        guard let conflict, let libraryURL, let repository,
              let index = notes.firstIndex(where: { $0.id == conflict.noteID }) else { return }
        let appVersion = notes[index]
        do {
            let ext = URL(fileURLWithPath: appVersion.filename).pathExtension
            let stem = try FilenamePolicy.sanitizedStem("\(appVersion.title) App")
            let filename = FilenamePolicy.availableFilename(stem: stem, extension: ext, in: libraryURL)
            guard case .saved(let hash, let date, let identity) = try await repository.create(filename: filename, body: conflict.appBody, lineEnding: appVersion.lineEnding) else { return }
            let copy = Note(
                title: URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent,
                body: conflict.appBody, createdAt: date, modifiedAt: date,
                revision: appVersion.revision + 1, filename: filename,
                lastSavedHash: hash, lineEnding: appVersion.lineEnding, fileIdentity: identity
            )
            notes[index].body = conflict.fileBody
            notes[index].lastSavedHash = conflict.fileHash
            notes[index].revision += 1
            searchDocuments[notes[index].id] = SearchDocument(note: notes[index])
            staleSearchDocumentIDs.remove(notes[index].id)
            baseBodies[notes[index].id] = conflict.fileBody
            notes.append(copy)
            searchDocuments[copy.id] = SearchDocument(note: copy)
            staleSearchDocumentIDs.remove(copy.id)
            recomputeDuplicateTitleKeys()
            baseBodies[copy.id] = copy.body
            dirtyNoteIDs.remove(appVersion.id)
            self.conflict = nil
            scheduleCacheUpsert(notes[index])
            scheduleCacheUpsert(copy)
            select([copy.id], explicitly: true)
            refreshSearch()
        } catch { errorMessage = error.localizedDescription }
    }

    func flushAll() async throws {
        settingsTask?.cancel()
        for task in journalTasks.values { task.cancel() }
        for task in journalDeadlineTasks.values { task.cancel() }
        journalTasks.removeAll()
        journalDeadlineTasks.removeAll()
        for id in Array(dirtyNoteIDs) { await writeJournalNow(id) }
        for task in saveTasks.values { task.cancel() }
        saveTasks.removeAll()
        for id in Array(dirtyNoteIDs) { await save(id) }
        if let settingsRepository { try await settingsRepository.save(settingsSnapshot()) }
    }

    private func createNote(title: String) async {
        guard !isReadOnly, let libraryURL, let repository else { return }
        do {
            let stem = try FilenamePolicy.sanitizedStem(title)
            let filename = FilenamePolicy.availableFilename(stem: stem, extension: defaultExtension, in: libraryURL)
            guard confirmMaterialTitleChange(input: title, final: URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent) else { return }
            let result = try await repository.create(filename: filename, body: "")
            guard case .saved(let hash, let date, let identity) = result else { return }
            let note = Note(title: URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent, body: "", createdAt: date, modifiedAt: date, filename: filename, lastSavedHash: hash, fileIdentity: identity)
            notes.append(note)
            searchDocuments[note.id] = SearchDocument(note: note)
            staleSearchDocumentIDs.remove(note.id)
            recomputeDuplicateTitleKeys()
            baseBodies[note.id] = ""
            scheduleCacheUpsert(note)
            let previousQuery = query
            let previousSelection = selection
            navigationHistory.append((previousQuery, previousSelection))
            priorExplicitQuery = previousQuery
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

    private func commitRename() async {
        guard let libraryURL, let repository, let note = selectedNote,
              let index = notes.firstIndex(where: { $0.id == note.id }) else { return }
        do {
            let stem = try FilenamePolicy.sanitizedStem(searchText)
            let ext = URL(fileURLWithPath: note.filename).pathExtension
            let filename = FilenamePolicy.availableFilename(
                stem: stem, extension: ext, in: libraryURL,
                excluding: libraryURL.appendingPathComponent(note.filename)
            )
            let finalTitle = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
            guard confirmMaterialTitleChange(input: searchText, final: finalTitle) else { return }
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
            isRenaming = false
            searchText = renameOriginalQuery
            query = renameOriginalQuery
            refreshSearch()
        } catch { errorMessage = error.localizedDescription }
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
        let staleNotes = notes.filter { staleSearchDocumentIDs.contains($0.id) }
        let normalizedTerms = query.terms.map { TextNormalizer.normalize($0.value) }
        let conservativeIDs = Set(notes.compactMap { note in
            cacheIndexedSearchVersions[note.id] == SearchIndexVersion(note) ? nil : note.id
        })
        let cache = cache
        let sort = sort
        let refinementDocuments: [SearchDocument]? = {
            guard staleNotes.isEmpty,
                  lastAppliedSearchDocumentsGeneration == searchDocumentsGeneration,
                  let previousQuery = lastAppliedSearchQuery,
                  SearchService.canIncrementallyRefine(from: previousQuery, to: query) else { return nil }
            let candidates = results.compactMap { cachedDocuments[$0.id] }
            return candidates.count == results.count ? candidates : nil
        }()
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            let worker = Task.detached(priority: .userInitiated) {
                let candidateIDs: Set<UUID>?
                if refinementDocuments != nil {
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
                let candidateCount = refinementDocuments?.count
                    ?? candidateIDs?.count
                    ?? cachedDocuments.count
                if SearchService.shouldDebounce(candidateCount: candidateCount) {
                    do { try await Task.sleep(for: .milliseconds(30)) }
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
        results = found
        let available = Set(found.map(\.id))
        if selectionKind == .explicit {
            selection.formIntersection(available)
        } else if let automatic = SearchService.automaticMatch(query: query.rawValue, results: found, sort: sort) {
            selection = [automatic]
            selectionKind = .automatic
        } else {
            selection = []
            selectionKind = .none
        }
        populateSelectedHighlightRanges()
        if scrollToTopAfterNextSearch {
            scrollToTopAfterNextSearch = false
            if let first = found.first {
                requestListScroll(to: first.id, placement: .top)
            }
        }
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

    private func scheduleCacheReplaceAll(_ notes: [Note]) {
        guard let cache else { return }
        let versions = searchIndexVersions(for: notes)
        Task { [weak self] in
            let succeeded = await Task.detached(priority: .utility) {
                do {
                    try cache.replaceAll(with: notes)
                    return true
                } catch {
                    return false
                }
            }.value
            guard succeeded, let self, self.cache === cache else { return }
            self.cacheIndexedSearchVersions = versions
        }
    }

    private func searchIndexVersions(for notes: [Note]) -> [UUID: SearchIndexVersion] {
        Dictionary(uniqueKeysWithValues: notes.map { ($0.id, SearchIndexVersion($0)) })
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
        guard dirtyNoteIDs.contains(id), let repository else { return }
        await writeJournalNow(id)
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        let snapshot = notes[index]
        do {
            switch try await repository.save(note: snapshot) {
            case .saved(let hash, let date, let identity):
                guard let current = notes.firstIndex(where: { $0.id == id }) else { return }
                if notes[current].revision == snapshot.revision {
                    dirtyNoteIDs.remove(id)
                    saveTasks[id] = nil
                    deadlineTasks[id]?.cancel()
                    deadlineTasks[id] = nil
                } else {
                    notes[current].lastSavedHash = hash
                    scheduleSave(for: id)
                }
                notes[current].lastSavedHash = hash
                notes[current].modifiedAt = date
                notes[current].fileIdentity = identity
                if let document = searchDocuments[id] {
                    searchDocuments[id] = document.replacingMetadata(with: notes[current])
                }
                baseBodies[id] = snapshot.body
                if let journalID = journalIDs[id], notes[current].revision == snapshot.revision {
                    try? await journal?.remove(journalID)
                    journalIDs[id] = nil
                }
                scheduleCacheUpsert(notes[current])
            case .conflict(let data, let hash):
                conflict = makeConflict(note: snapshot, data: data, hash: hash)
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

    private func reconcileExternalChanges(_ change: DirectoryWatcher.Change) async {
        guard let libraryURL else { return }
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
            for disk in scan.notes {
                guard let old = oldByFilename[disk.filename] else { reconciled.append(disk); continue }
                if disk.lastSavedHash == old.lastSavedHash { reconciled.append(old); continue }
                if dirtyNoteIDs.contains(old.id) {
                    conflict = Conflict(noteID: old.id, baseBody: baseBodies[old.id] ?? "", appBody: old.body, fileBody: disk.body, fileHash: disk.lastSavedHash)
                    reconciled.append(old)
                } else {
                    reconciled.append(disk)
                    baseBodies[disk.id] = disk.body
                    transientMessage = "“\(disk.title)” changed outside nvnv. Its undo history was cleared."
                }
            }
            for old in notes where !scan.notes.contains(where: { $0.filename == old.filename }) {
                if dirtyNoteIDs.contains(old.id) {
                    conflict = Conflict(noteID: old.id, baseBody: baseBodies[old.id] ?? "", appBody: old.body, fileBody: "", fileHash: "")
                    reconciled.append(old)
                }
            }
            notes = reconciled
            searchDocuments = Dictionary(uniqueKeysWithValues: reconciled.map { ($0.id, SearchDocument(note: $0)) })
            staleSearchDocumentIDs.removeAll()
            recomputeDuplicateTitleKeys()
            scanIssues = scan.issues
            if !isReadOnly, cache != nil {
                scheduleCacheReplaceAll(reconciled)
            }
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
                        case .saved(let hash, let date, let identity):
                            notes[index].lastSavedHash = hash
                            notes[index].modifiedAt = date
                            notes[index].fileIdentity = identity
                            baseBodies[notes[index].id] = notes[index].body
                            try await journal.remove(entry.id)
                            transientMessage = "Recovered “\(notes[index].title)” after an interrupted save."
                        case .conflict(let data, let hash):
                            conflict = makeConflict(note: notes[index], data: data, hash: hash)
                        }
                    } else {
                        notes[index].body = entry.body
                        conflict = makeConflict(note: notes[index], data: try await repository.data(for: entry.filename), hash: notes[index].lastSavedHash)
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
        showModifiedDate = settings.showModifiedDate
        showCreatedDate = settings.showCreatedDate
        showExcerpts = settings.showExcerpts
        confirmDeletion = settings.confirmDeletion
        highlightSearch = settings.highlightSearch
        // Version 1 shipped with 13 pt as the default. Migrate only that exact
        // legacy default; preserve sizes the user deliberately selected.
        listFontSize = settings.schemaVersion < 2 && settings.listFontSize == 13
            ? 11
            : settings.listFontSize
        editorFontName = settings.editorFontName
        // Version 2 and earlier shipped with 14 pt as the default editor size.
        // Migrate only that exact default and preserve deliberate custom sizes.
        editorFontSize = settings.schemaVersion < 3 && settings.editorFontSize == 14
            ? 12
            : settings.editorFontSize
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
        settings.showModifiedDate = showModifiedDate
        settings.showCreatedDate = showCreatedDate
        settings.showExcerpts = showExcerpts
        settings.confirmDeletion = confirmDeletion
        settings.highlightSearch = highlightSearch
        settings.listFontSize = listFontSize
        settings.editorFontName = editorFontName
        settings.editorFontSize = editorFontSize
        settings.softTabs = softTabs
        settings.tabWidth = tabWidth
        settings.tabIndents = tabIndents
        settings.recognizedExtensions = recognizedExtensions
        settings.defaultExtension = defaultExtension
        return settings
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

enum ListScrollPlacement: Equatable {
    case minimal
    case top
}
