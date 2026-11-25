import NVNVCore
import SwiftUI

/// Secondary status text below the editor. It appears only while it has
/// something to report, so the three main areas keep their space otherwise.
struct StatusBar: View {
    @Bindable var model: AppModel
    @State private var isShowingScanIssues = false

    var body: some View {
        if model.scanIssueSummary != nil || model.transientMessage != nil || model.isIndexing {
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
            }
            .font(.system(size: 10.5))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .overlay(alignment: .top) { Divider() }
        }
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
