import NVNVCore
import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var undoRegistry = EditorUndoRegistry()
    @State private var dividerDragStart: Double?

    var body: some View {
        Group {
            if model.libraryURL == nil {
                WelcomeView(model: model)
            } else {
                libraryView
            }
        }
        .frame(minWidth: 680, minHeight: 560)
        .task { await model.restoreLastLibrary() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { Task { try? await model.flushAll() } }
        }
        .alert("nvnv", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .sheet(isPresented: $model.isConflictPresented) {
            if let conflict = model.conflict { ConflictView(model: model, conflict: conflict) }
        }
    }

    private var libraryView: some View {
        VStack(spacing: 0) {
            SearchBar(model: model)
            if model.isReadOnly {
                Label("Read-only — another nvnv process owns this library", systemImage: "lock.fill")
                    .font(.caption).foregroundStyle(.orange).padding(.top, 6)
            }
            GeometryReader { proxy in
                let usable = max(proxy.size.height - 7, 1)
                VStack(spacing: 0) {
                    NoteListView(model: model)
                        .frame(height: usable * model.dividerFraction)
                    Color.clear
                        .frame(height: 7)
                        .overlay {
                            Capsule()
                                .fill(.tertiary)
                                .frame(width: 30, height: 3)
                        }
                        .background(.separator.opacity(0.35))
                        .contentShape(Rectangle())
                        .gesture(DragGesture()
                            .onChanged { value in
                                if dividerDragStart == nil { dividerDragStart = model.dividerFraction }
                                model.dividerFraction = min(max((dividerDragStart ?? model.dividerFraction) + value.translation.height / usable, 0.18), 0.76)
                            }
                            .onEnded { _ in dividerDragStart = nil })
                    EditorPane(model: model, undoRegistry: undoRegistry)
                }
            }
            statusBar
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.navigateBack() } label: { Label("Back", systemImage: "arrow.uturn.backward") }
                    .disabled(model.libraryURL == nil)
                Button { model.startRename() } label: { Label("Rename", systemImage: "pencil") }
                    .disabled(model.isReadOnly || model.selection.count != 1)
                Button { model.revealSelectedNote() } label: { Label("Show in Finder", systemImage: "folder") }
                    .disabled(model.selection.count != 1)
            }
        }
    }

    private var statusBar: some View {
        HStack {
            if let message = model.transientMessage {
                Text(message).lineLimit(1)
            } else if !model.scanIssues.isEmpty {
                Label("\(model.scanIssues.count) file \(model.scanIssues.count == 1 ? "issue" : "issues")", systemImage: "exclamationmark.triangle")
            } else {
                Text(model.libraryURL?.path(percentEncoded: false) ?? "")
            }
            Spacer()
            if model.selection.count > 1 { Text("\(model.selection.count) selected") }
            else if let count = model.wordCount { Text("\(count) \(count == 1 ? "word" : "words")") }
            Text("\(model.results.count) \(model.results.count == 1 ? "note" : "notes")")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .frame(height: 25)
        .background(.bar)
    }
}

private struct WelcomeView: View {
    let model: AppModel
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "note.text").font(.system(size: 48)).foregroundStyle(.secondary)
            Text("nvnv").font(.largeTitle.weight(.semibold))
            Text("Fast, keyboard-first notes stored as plain text files.")
                .foregroundStyle(.secondary)
            Button("Open Notes Folder…") { Task { await model.chooseLibrary() } }
                .buttonStyle(.borderedProminent).controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ConflictView: View {
    let model: AppModel
    let conflict: NVNVCore.Conflict
    @State private var showMerge = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Label("This note changed in nvnv and on disk", systemImage: "exclamationmark.triangle.fill")
                    .font(.title2.weight(.semibold)).foregroundStyle(.orange)
                Text("Both versions are preserved. Choose which body should remain authoritative.")
                HSplitView {
                    version("App Version", conflict.appBody)
                    version("File Version", conflict.fileBody)
                }
                .frame(minHeight: 260)
                HStack {
                    Button("Resolve Later") { model.deferConflict() }
                    Button("Open File Externally") { model.openConflictFileExternally() }
                    Spacer()
                    Button("Use File") { model.resolveConflictUseFile() }
                    Button("Keep Both") { Task { await model.resolveConflictKeepBoth() } }
                    Button("Merge…") { showMerge = true }
                    Button("Keep App") { Task { await model.resolveConflictKeepApp() } }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(20)
            .navigationDestination(isPresented: $showMerge) {
                MergeConflictView(model: model, conflict: conflict)
            }
        }
        .frame(minWidth: 720, minHeight: 420)
    }

    private func version(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading) {
            Text(title).font(.headline)
            ScrollView { Text(body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(8) }
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        }.padding(4)
    }
}

private struct MergeConflictView: View {
    let model: AppModel
    let conflict: NVNVCore.Conflict
    @State private var merged: String

    init(model: AppModel, conflict: NVNVCore.Conflict) {
        self.model = model
        self.conflict = conflict
        _merged = State(initialValue: conflict.appBody)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Merge Versions").font(.title2.weight(.semibold))
            Text("Edit the final plain-text body. The file is checked again before it is replaced.").foregroundStyle(.secondary)
            TextEditor(text: $merged).font(.body.monospaced()).border(.separator)
            HStack { Spacer(); Button("Commit Merge") { Task { await model.resolveConflictMerge(body: merged) } }.buttonStyle(.borderedProminent) }
        }.padding(18).frame(minWidth: 680, minHeight: 440)
    }
}
