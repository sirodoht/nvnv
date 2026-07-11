import NVNVCore
import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var undoRegistry = EditorUndoRegistry()
    @State private var dividerDragStart: Double?

    var body: some View {
        Group {
            if model.libraryURL != nil || model.isRestoringLibrary {
                libraryView
            } else {
                WelcomeView(model: model)
            }
        }
        .frame(minWidth: 440, minHeight: 560)
        .background(WindowChromeConfigurator())
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
                    .font(.system(size: 10.5))
                    .foregroundStyle(.orange)
                    .padding(.vertical, 2)
            }
            GeometryReader { proxy in
                let dividerHeight: CGFloat = 10
                let usable = max(proxy.size.height - dividerHeight, 1)
                VStack(spacing: 0) {
                    NoteListView(model: model)
                        .frame(height: usable * model.dividerFraction)
                    Color.clear
                        .frame(height: dividerHeight)
                        .overlay {
                            Capsule()
                                .fill(.tertiary)
                                .frame(width: 30, height: 2)
                        }
                        .background(.separator.opacity(0.25))
                        .contentShape(Rectangle())
                        .onHover { hovering in
                            if hovering { NSCursor.resizeUpDown.push() }
                            else { NSCursor.pop() }
                        }
                        .gesture(DragGesture(coordinateSpace: .global)
                            .onChanged { value in
                                if dividerDragStart == nil { dividerDragStart = model.dividerFraction }
                                model.dividerFraction = min(max((dividerDragStart ?? model.dividerFraction) + value.translation.height / usable, 0.18), 0.76)
                            }
                            .onEnded { _ in dividerDragStart = nil })
                    EditorPane(model: model, undoRegistry: undoRegistry)
                }
            }
        }
    }
}

private struct WindowChromeConfigurator: NSViewRepresentable {
    private static let titleIdentifier = NSUserInterfaceItemIdentifier("nvnv.centered-window-title")

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        configureWhenAttached(view)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        configureWhenAttached(view)
    }

    private func configureWhenAttached(_ view: NSView) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.titleVisibility = .hidden
            guard
                let closeButton = window.standardWindowButton(.closeButton),
                let titlebar = closeButton.superview,
                let contentView = window.contentView
            else { return }

            if titlebar.subviews.contains(where: { $0.identifier == Self.titleIdentifier }) { return }

            let label = DraggableWindowTitle(labelWithString: window.title)
            label.identifier = Self.titleIdentifier
            label.font = .systemFont(ofSize: 13, weight: .semibold)
            label.textColor = .labelColor
            label.alignment = .center
            label.translatesAutoresizingMaskIntoConstraints = false
            titlebar.addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            ])
        }
    }
}

private final class DraggableWindowTitle: NSTextField {
    override var mouseDownCanMoveWindow: Bool { true }
}

private struct WelcomeView: View {
    let model: AppModel
    var body: some View {
        VStack(spacing: 18) {
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
