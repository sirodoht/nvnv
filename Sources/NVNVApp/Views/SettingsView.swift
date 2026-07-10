import AppKit
import NVNVCore
import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var fontPanelController = EditorFontPanelController()

    var body: some View {
        Form {
            Section("Note List") {
                Toggle("Show body excerpts", isOn: $model.showExcerpts)
                Toggle("Show date modified", isOn: $model.showModifiedDate)
                Toggle("Show date created", isOn: $model.showCreatedDate)
                HStack { Text("Text size"); Slider(value: $model.listFontSize, in: 9...24, step: 1); Text("\(Int(model.listFontSize)) pt").monospacedDigit() }
                Picker("Sort", selection: $model.sort.field) {
                    Text("Title").tag(NoteSortField.title)
                    Text("Date Modified").tag(NoteSortField.modified)
                    Text("Date Created").tag(NoteSortField.created)
                }
                Toggle("Ascending", isOn: $model.sort.ascending)
            }
            Section("Editor") {
                HStack {
                    Text("Font")
                    Spacer()
                    Text(editorFontDisplayName)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Button("Choose…") { fontPanelController.show(for: model) }
                    Button("Default") {
                        model.editorFontName = ""
                        model.editorFontSize = 12
                    }
                }
                HStack { Text("Text size"); Slider(value: $model.editorFontSize, in: 10...72, step: 1); Text("\(Int(model.editorFontSize)) pt").monospacedDigit() }
                Toggle("Use spaces for indentation", isOn: $model.softTabs)
                Toggle("Tab indents text", isOn: $model.tabIndents)
                Stepper("Tab width: \(model.tabWidth)", value: $model.tabWidth, in: 1...16)
                Toggle("Highlight search matches", isOn: $model.highlightSearch)
            }
            Section("Safety") { Toggle("Confirm before moving notes to Trash", isOn: $model.confirmDeletion) }
            Section("Files") {
                TextField("Recognized extensions (comma-separated)", text: $model.extensionList)
                TextField("Default extension", text: $model.defaultExtension)
                Text("The default extension is always recognized. Changes take effect on the next filesystem reconciliation.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding().frame(width: 520, height: 520)
        .onDisappear { fontPanelController.stop() }
    }

    private var editorFontDisplayName: String {
        let font = model.editorFontName.isEmpty
            ? NSFont.monospacedSystemFont(ofSize: model.editorFontSize, weight: .regular)
            : NSFont(name: model.editorFontName, size: model.editorFontSize)
        return font?.displayName ?? "System Monospace"
    }
}

@MainActor
private final class EditorFontPanelController: NSObject {
    private weak var model: AppModel?

    func show(for model: AppModel) {
        self.model = model
        let currentFont = resolvedFont(for: model)
        let manager = NSFontManager.shared
        manager.setSelectedFont(currentFont, isMultiple: false)
        manager.target = self
        manager.action = #selector(changeFont(_:))
        manager.orderFrontFontPanel(nil)
    }

    func stop() {
        let manager = NSFontManager.shared
        if manager.target === self { manager.target = nil }
        model = nil
    }

    @objc private func changeFont(_ sender: NSFontManager) {
        guard let model else { return }
        let converted = sender.convert(resolvedFont(for: model))
        model.editorFontName = converted.fontName
        model.editorFontSize = Double(converted.pointSize)
    }

    private func resolvedFont(for model: AppModel) -> NSFont {
        if !model.editorFontName.isEmpty,
           let chosen = NSFont(name: model.editorFontName, size: model.editorFontSize) {
            return chosen
        }
        return NSFont.monospacedSystemFont(ofSize: model.editorFontSize, weight: .regular)
    }
}
