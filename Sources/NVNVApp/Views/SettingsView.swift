import NVNVCore
import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel
    var body: some View {
        Form {
            Section("Note List") {
                Toggle("Show body excerpts", isOn: $model.showExcerpts)
                Toggle("Show date modified", isOn: $model.showModifiedDate)
                Toggle("Show date created", isOn: $model.showCreatedDate)
                Toggle("Show word count", isOn: $model.showWordCount)
                HStack { Text("Text size"); Slider(value: $model.listFontSize, in: 10...24, step: 1); Text("\(Int(model.listFontSize)) pt").monospacedDigit() }
                Picker("Sort", selection: $model.sort.field) {
                    Text("Title").tag(NoteSortField.title)
                    Text("Date Modified").tag(NoteSortField.modified)
                    Text("Date Created").tag(NoteSortField.created)
                }
                Toggle("Ascending", isOn: $model.sort.ascending)
            }
            Section("Editor") {
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
    }
}
