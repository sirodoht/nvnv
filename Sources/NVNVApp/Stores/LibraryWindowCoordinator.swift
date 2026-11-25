import AppKit
import NVNVCore
import Observation

@MainActor
@Observable
final class LibraryCatalogStore {
    var catalog: LibraryCatalog
    let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        catalog = LibraryCatalog.load(data: userDefaults.data(forKey: "namedLibraries"),
                                      legacyPath: userDefaults.string(forKey: "lastLibraryPath"))
    }

    func persist() {
        if let data = try? JSONEncoder().encode(catalog) {
            userDefaults.set(data, forKey: "namedLibraries")
        }
        if let active = catalog.activeLibrary {
            userDefaults.set(active.path, forKey: "lastLibraryPath")
        } else {
            userDefaults.removeObject(forKey: "lastLibraryPath")
        }
    }
}

/// Owns application-wide registrations and one live session per canonical library.
@MainActor
@Observable
final class LibraryWindowCoordinator {
    let catalogStore: LibraryCatalogStore
    private(set) var models: [AppModel] = []
    private(set) var focusedModel: AppModel?
    var settingsLibraryID: UUID?
    var settingsModel: AppModel? {
        guard let settingsLibraryID else { return nil }
        return models.first { $0.activeLibrary?.id == settingsLibraryID }
    }
    private(set) var isQuitting = false
    private(set) var openLibraryIDs: [UUID]
    @ObservationIgnored private var controllers: [UUID: LibraryWindowController] = [:]
    @ObservationIgnored private var previousLibraryIDs: [UUID: UUID] = [:]
    @ObservationIgnored private var sessions: [String: LibrarySession] = [:]
    @ObservationIgnored private var openingPaths: Set<String> = []
    @ObservationIgnored private var hasRestoredWorkspace = false
    @ObservationIgnored private var isRestoringWorkspace = false
    @ObservationIgnored var makeWindow: ((AppModel) -> NSWindow)?

    init(userDefaults: UserDefaults = .standard) {
        let store = LibraryCatalogStore(userDefaults: userDefaults)
        catalogStore = store
        if let saved = userDefaults.stringArray(forKey: "openLibraryWindows") {
            var seen: Set<UUID> = []
            openLibraryIDs = saved.compactMap(UUID.init(uuidString:)).filter { id in
                seen.insert(id).inserted && store.catalog.libraries.contains { library in library.id == id }
            }
        } else {
            openLibraryIDs = catalogStore.catalog.activeID.map { [$0] } ?? []
        }
    }

    func makeModel(for libraryID: UUID? = nil) -> AppModel {
        if let libraryID, let existing = models.first(where: { $0.activeLibrary?.id == libraryID }) {
            return existing
        }
        let model = AppModel(userDefaults: catalogStore.userDefaults, catalogStore: catalogStore)
        model.windowCoordinator = self
        models.append(model)
        return model
    }

    func restoreWorkspace(into initialModel: AppModel) async {
        guard !hasRestoredWorkspace else { return }
        hasRestoredWorkspace = true
        isRestoringWorkspace = true
        defer {
            isRestoringWorkspace = false
            persistWorkspace()
        }
        let savedIDs = openLibraryIDs
        var errors: [String] = []
        for id in savedIDs {
            guard let library = catalogStore.catalog.libraries.first(where: { $0.id == id }) else { continue }
            await open(library.url, from: initialModel, inNewWindow: initialModel.libraryURL != nil)
            if let error = initialModel.errorMessage {
                errors.append("\(library.name): \(error)")
                initialModel.errorMessage = nil
            }
        }
        if !errors.isEmpty { initialModel.errorMessage = errors.joined(separator: "\n\n") }
    }

    func open(_ url: URL, from source: AppModel, inNewWindow: Bool) async {
        guard !isQuitting else { return }
        let canonical = LibraryCatalog.canonicalURL(url)
        if let existing = models.first(where: { $0.libraryURL == canonical }) {
            show(existing)
            return
        }
        guard !openingPaths.contains(canonical.path), inNewWindow || !source.isSwitchingLibrary else { return }
        openingPaths.insert(canonical.path)
        defer { openingPaths.remove(canonical.path) }
        let target = inNewWindow ? makeModel() : source
        if let session = sessions[canonical.path] { target.rememberSession(session, at: canonical) }
        await target.openLibrary(canonical, confirmedAuxiliaryCreation: true)
        guard target.libraryURL == canonical else {
            if target !== source {
                source.errorMessage = target.errorMessage
                target.finishWindowClose()
                models.removeAll { $0 === target }
            }
            return
        }
        if target !== source { show(target) }
    }

    func rememberSession(_ session: LibrarySession, at url: URL) {
        sessions[url.path] = session
    }

    func didOpen(_ model: AppModel) {
        guard let id = model.activeLibrary?.id else { return }
        if let previous = previousLibraryIDs[model.windowID], previous != id,
           !models.contains(where: { $0 !== model && $0.activeLibrary?.id == previous }) {
            openLibraryIDs.removeAll { $0 == previous }
        }
        previousLibraryIDs[model.windowID] = id
        if !openLibraryIDs.contains(id) { openLibraryIDs.append(id) }
        persistWorkspace()
    }

    func remove(_ library: NamedLibrary, from source: AppModel) async {
        guard !isQuitting, !openingPaths.contains(LibraryCatalog.canonicalURL(library.url).path) else { return }
        let target = models.first { $0.activeLibrary?.id == library.id } ?? source
        guard !target.isSwitchingLibrary else { return }
        await target.removeLibraryRegistration(library)
        guard !catalogStore.catalog.libraries.contains(where: { $0.id == library.id }) else {
            if target !== source { source.errorMessage = target.errorMessage }
            return
        }
        sessions[library.path] = nil
        openLibraryIDs.removeAll { $0 == library.id }
        previousLibraryIDs[target.windowID] = target.activeLibrary?.id
        persistWorkspace()
    }

    func show(_ model: AppModel) {
        if controllers[model.windowID] == nil, let window = makeWindow?(model) {
            // The factory must return an unshown window. Attach restores its
            // frame synchronously, before its first order-front operation.
            attach(window, to: model)
        }
        controllers[model.windowID]?.present()
        model.focusSearch()
    }

    func newWindow() {
        guard !isQuitting else { return }
        show(makeModel())
    }

    func attach(_ window: NSWindow, to model: AppModel) {
        if let controller = controllers[model.windowID], let existing = controller.window {
            if existing !== window {
                // Keep one native window per session even if a caller tries
                // to attach a second window to the same model.
                existing.makeKeyAndOrderFront(nil)
                window.close()
            } else {
                controller.synchronize()
            }
            return
        }
        let controller = LibraryWindowController(window: window, model: model, coordinator: self)
        controllers[model.windowID] = controller
        controller.synchronize()
    }

    func focused(_ model: AppModel) {
        focusedModel = model
        guard let url = model.libraryURL else { return }
        catalogStore.catalog.activate(url)
        catalogStore.persist()
    }

    func unfocused(_ model: AppModel) {
        if focusedModel === model { focusedModel = nil }
    }

    func synchronizeWindow(for model: AppModel) {
        controllers[model.windowID]?.synchronize()
    }

    func didClose(_ model: AppModel) {
        unfocused(model)
        if let url = model.libraryURL { sessions[url.path] = model.sessionSnapshot() }
        if !isQuitting, let id = model.activeLibrary?.id {
            openLibraryIDs.removeAll { $0 == id }
        }
        previousLibraryIDs[model.windowID] = nil
        controllers[model.windowID] = nil
        if settingsLibraryID == model.activeLibrary?.id { settingsLibraryID = nil }
        model.finishWindowClose()
        models.removeAll { $0 === model }
        if !isQuitting { persistWorkspace() }
    }

    func prepareForQuit() async throws {
        guard !isQuitting else { return }
        // Capture native frames before freezing sessions, so the final settings
        // flush doesn't depend on the last move/resize notification arriving.
        for controller in controllers.values { controller.recordFrame() }
        isQuitting = true
        var errors: [String] = []
        // Freeze every session and attempt every flush, even if another fails.
        let snapshot = models
        for model in snapshot {
            do { try await model.prepareForWindowClose() }
            catch { errors.append("\(model.activeLibrary?.name ?? "Library"): \(error.localizedDescription)") }
        }
        if !errors.isEmpty {
            isQuitting = false
            for model in snapshot { model.cancelWindowClose() }
            throw NSError(domain: "app.nvnv", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: errors.joined(separator: "\n\n")])
        }
        persistWorkspace()
    }

    private func persistWorkspace() {
        guard !isRestoringWorkspace else { return }
        catalogStore.userDefaults.set(openLibraryIDs.map(\.uuidString), forKey: "openLibraryWindows")
    }
}
