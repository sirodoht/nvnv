import NVNVCore
import SwiftUI

/// Secondary status text below the editor. It appears only while it has
/// something to report, so the three main areas keep their space otherwise.
struct StatusBar: View {
    @Bindable var model: AppModel
    @State private var isShowingScanIssues = false
    @State private var countedWords: CountedWords?

    private struct CountedWords {
        let noteID: UUID
        let count: Int
    }

    private struct WordCountInput: Equatable {
        let noteID: UUID?
        let revision: Int
    }

    private var countsWords: Bool { model.showWordCount && !model.selection.isEmpty }

    private var countStatus: String? {
        guard model.showWordCount else { return nil }
        let words = countedWords.flatMap { $0.noteID == model.selectedNote?.id ? $0.count : nil }
        return AppModel.countStatus(selectionCount: model.selection.count, wordCount: words)
    }

    var body: some View {
        if model.scanIssueSummary != nil || model.transientMessage != nil || model.isIndexing || countsWords {
            HStack(spacing: 8) {
                if let summary = model.scanIssueSummary {
                    Button { isShowingScanIssues = true } label: {
                        Label(summary, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    .buttonStyle(.plain)
                    .help("Show the files nvnv could not fully read")
                    .popover(isPresented: $isShowingScanIssues, arrowEdge: .top) {
                        ScanIssueList(model: model)
                    }
                }
                if let message = model.transientMessage {
                    Text(message)
                        .foregroundStyle(.secondary)
                        .truncationMode(.middle)
                        .help(message)
                        .onTapGesture { model.dismissTransientMessage() }
                }
                Spacer(minLength: 0)
                if model.isIndexing {
                    // Search stays complete meanwhile; it only runs slower.
                    ProgressView().controlSize(.mini)
                    Text("Indexing…").foregroundStyle(.secondary)
                }
                if let countStatus {
                    Text(countStatus).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .task(id: WordCountInput(
                noteID: countsWords ? model.selectedNote?.id : nil,
                revision: model.selectedNote?.revision ?? 0
            )) { await countWords() }
            .font(.system(size: 10.5))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .overlay(alignment: .top) { Divider() }
        }
    }
}

extension StatusBar {
    /// Counts a newly shown note at once, and follows typing after a pause.
    private func countWords() async {
        guard countsWords, let note = model.selectedNote else {
            countedWords = nil
            return
        }
        if countedWords?.noteID == note.id {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
        }
        let body = model.selectedNote?.id == note.id ? model.selectedNote?.body ?? note.body : note.body
        let count = await Task.detached(priority: .utility) { WordCounter.count(body) }.value
        guard !Task.isCancelled else { return }
        countedWords = CountedWords(noteID: note.id, count: count)
    }
}

private struct ScanIssueList: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Files nvnv could not fully read").font(.headline)
            Text("These files are in the library folder and were left untouched.")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(model.scanIssues) { issue in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(issue.filename).lineLimit(1).truncationMode(.middle)
                                Text(issue.message).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Show in Finder") { model.reveal(issue) }
                                .controlSize(.small)
                        }
                    }
                }
            }
            .frame(maxHeight: 240)
        }
        .padding(14)
        .frame(width: 420)
    }
}
