import NVNVCore
import SwiftUI

struct LibraryPicker: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack {
            Menu {
                ForEach(model.libraries) { library in
                    Button {
                        Task { await model.switchLibrary(to: library) }
                    } label: {
                        if model.activeLibrary?.id == library.id {
                            Label(library.name, systemImage: "checkmark")
                        } else {
                            Text(library.name)
                        }
                    }
                    .help(library.path)
                }
                Divider()
                Button("Switch Library…") { model.showLibrarySwitcher() }
                Button("Add Library…") { Task { await model.chooseLibrary() } }
                if let library = model.activeLibrary {
                    Divider()
                    Button("Rename Library…") { model.beginRenamingLibrary(library) }
                    Button("Remove Library from List…") { model.libraryToRemove = library }
                }
            } label: {
                Label(model.activeLibrary?.name ?? "Libraries", systemImage: "books.vertical")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .menuStyle(.borderlessButton)
            .fixedSize(horizontal: false, vertical: true)
            .help(model.libraryURL?.path ?? "Switch Library (⇧⌘L)")
            .accessibilityLabel("Library")
            Spacer(minLength: 8)
            if model.isSwitchingLibrary {
                ProgressView().controlSize(.small)
                Text("Opening library…").foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .disabled(model.isSwitchingLibrary)
    }
}

struct LibrarySwitcher: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var filter = ""
    @State private var selectedID: UUID?
    @FocusState private var searchFocused: Bool

    private var matches: [NamedLibrary] {
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.libraries.filter {
            query.isEmpty || $0.name.localizedStandardContains(query) || $0.path.localizedStandardContains(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Switch Library").font(.headline)
            TextField("Find a library", text: $filter)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .onSubmit { openSelection() }
                .onKeyPress(.downArrow) { moveSelection(by: 1); return .handled }
                .onKeyPress(.upArrow) { moveSelection(by: -1); return .handled }
            if matches.isEmpty {
                ContentUnavailableView(
                    model.libraries.isEmpty ? "No Libraries Yet" : "No Matching Libraries",
                    systemImage: "books.vertical",
                    description: Text(model.libraries.isEmpty ? "Add a notes folder to get started." : "Try another name or folder path.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selectedID) {
                    ForEach(matches) { library in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(library.name).lineLimit(1)
                                Text(library.path).font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            if model.activeLibrary?.id == library.id {
                                Image(systemName: "checkmark").foregroundStyle(.secondary)
                                    .accessibilityLabel("Active library")
                            }
                        }
                        .tag(library.id)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { open(library) }
                    }
                }
                .listStyle(.bordered)
            }
            HStack {
                Button("Add Library…") {
                    model.librarySwitcherAction = .add
                    dismiss()
                }
                if let library = matches.first(where: { $0.id == selectedID }) {
                    Menu {
                        Button("Rename…") {
                            model.librarySwitcherAction = .rename(library)
                            dismiss()
                        }
                        Button("Remove from List…") {
                            model.librarySwitcherAction = .remove(library)
                            dismiss()
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .accessibilityLabel("Manage selected library")
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Open") { openSelection() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!matches.contains { $0.id == selectedID })
            }
        }
        .padding(18)
        .frame(width: 480, height: 360)
        .onAppear {
            selectedID = model.activeLibrary?.id ?? matches.first?.id
            searchFocused = true
        }
        .onChange(of: filter) { _, _ in selectedID = matches.first?.id }
    }

    private func moveSelection(by offset: Int) {
        guard !matches.isEmpty else { return }
        let index = matches.firstIndex { $0.id == selectedID } ?? (offset > 0 ? -1 : matches.count)
        selectedID = matches[min(max(index + offset, 0), matches.count - 1)].id
    }

    private func openSelection() {
        guard let library = matches.first(where: { $0.id == selectedID }) else { return }
        open(library)
    }

    private func open(_ library: NamedLibrary) {
        model.librarySwitcherAction = .open(library)
        dismiss()
    }
}

struct LibraryManagement: ViewModifier {
    @Bindable var model: AppModel

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $model.isLibrarySwitcherPresented, onDismiss: {
                model.finishLibrarySwitcher()
            }) {
                LibrarySwitcher(model: model)
            }
            .alert("Rename Library", isPresented: Binding(
                get: { model.libraryToRename != nil },
                set: { if !$0 { model.libraryToRename = nil } }
            ), presenting: model.libraryToRename) { library in
                TextField("Library name", text: $model.libraryNameDraft)
                Button("Cancel", role: .cancel) {}
                Button("Rename") { model.renameLibrary(library, to: model.libraryNameDraft) }
                    .disabled(model.libraryNameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } message: { library in
                Text("Choose a display name for \(library.path). The folder name will stay the same.")
            }
            .alert("Remove Library from List?", isPresented: Binding(
                get: { model.libraryToRemove != nil },
                set: { if !$0 { model.libraryToRemove = nil } }
            ), presenting: model.libraryToRemove) { library in
                Button("Cancel", role: .cancel) {}
                Button("Remove from List") { Task { await model.removeLibrary(library) } }
            } message: { library in
                Text("Remove “\(library.name)” from nvnv’s library list? All notes and the folder’s .nvnv data will remain on disk.")
            }
    }
}
