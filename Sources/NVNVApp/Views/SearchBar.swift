import AppKit
import SwiftUI

struct SearchBar: View {
    @Bindable var model: AppModel
    @State private var focused = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: model.isShowingSelectedNoteTitle ? "pencil" : "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            CompletingSearchField(
                text: model.searchText,
                completionTitle: focused && model.selectionKind == .automatic
                    ? model.selectedNote?.title
                    : nil,
                placeholder: "Search or Create",
                focusRequest: model.focusRequest,
                onChange: { model.userEnteredSearchText($0) },
                onSubmit: { Task { await model.submitSearch() } },
                onMove: { model.moveSelection(by: $0) },
                onEscape: { model.clearOrCancel() },
                onFocusChange: { focused = $0 },
                onFocusRequestHandled: model.consumeFocusRequest
            )
            .frame(maxWidth: .infinity)
            if !model.searchText.isEmpty {
                Button { model.clearOrCancel() } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .help("Clear Search")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(.background, in: RoundedRectangle(cornerRadius: 5))
        .overlay {
            RoundedRectangle(cornerRadius: 5)
                .stroke(
                    focused ? Color.accentColor : Color.secondary.opacity(0.28),
                    lineWidth: focused ? 2 : 1
                )
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
    }
}

/// An AppKit-backed field is used here because SwiftUI's `TextField` cannot
/// select only the proposed part of an inline completion. The model continues
/// to own just the text the user entered; the field editor temporarily displays
/// the rest of the automatically selected note title.
struct CompletingSearchField: NSViewRepresentable {
    let text: String
    let completionTitle: String?
    let placeholder: String
    let focusRequest: FocusRequest?
    let onChange: (String) -> Void
    let onSubmit: () -> Void
    let onMove: (Int) -> Void
    let onEscape: () -> Void
    let onFocusChange: (Bool) -> Void
    let onFocusRequestHandled: (UUID) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 12)
        field.lineBreakMode = .byClipping
        field.delegate = context.coordinator
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        context.coordinator.updateField(field, text: text, completionTitle: completionTitle)
        context.coordinator.synchronizeFocus(for: field)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        field.placeholderString = placeholder
        context.coordinator.updateField(field, text: text, completionTitle: completionTitle)
        context.coordinator.synchronizeFocus(for: field)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: CompletingSearchField
        var lastFocusRequestID: UUID?
        var pendingFocusRequestID: UUID?

        private var isApplyingPresentation = false
        private var replacementWasDeletion = false
        private var completionSuppressedForText: String?
        private var lastPresentedText: String?
        private var lastPresentedCompletionTitle: String?

        init(_ parent: CompletingSearchField) {
            self.parent = parent
        }

        func updateField(_ field: NSTextField, text: String, completionTitle: String?) {
            if completionSuppressedForText != text {
                completionSuppressedForText = nil
            }
            let presentedCompletion = completionSuppressedForText == text ? nil : completionTitle
            let presentation = SearchFieldCompletion.presentation(
                typedText: text,
                completionTitle: presentedCompletion
            )

            if let editor = field.currentEditor() as? NSTextView {
                guard !editor.hasMarkedText() else { return }
                let presentationChanged = lastPresentedText != text
                    || lastPresentedCompletionTitle != presentedCompletion
                guard editor.string != presentation.string || presentationChanged else { return }

                isApplyingPresentation = true
                editor.string = presentation.string
                if let selection = presentation.completionRange {
                    editor.setSelectedRange(selection)
                } else if editor.selectedRange().location > (presentation.string as NSString).length {
                    editor.setSelectedRange(NSRange(location: (presentation.string as NSString).length, length: 0))
                }
                isApplyingPresentation = false
            } else if field.stringValue != presentation.string {
                isApplyingPresentation = true
                field.stringValue = presentation.string
                isApplyingPresentation = false
            }

            lastPresentedText = text
            lastPresentedCompletionTitle = presentedCompletion
        }

        func synchronizeFocus(for field: NSTextField) {
            guard let request = parent.focusRequest,
                  case .search = request.destination,
                  lastFocusRequestID != request.id else {
                pendingFocusRequestID = nil
                return
            }
            guard pendingFocusRequestID != request.id else { return }
            pendingFocusRequestID = request.id
            attemptFocus(request, for: field, remainingAttempts: 30)
        }

        private func attemptFocus(
            _ request: FocusRequest, for field: NSTextField, remainingAttempts: Int
        ) {
            guard pendingFocusRequestID == request.id,
                  parent.focusRequest?.id == request.id,
                  case .search(let selection) = request.destination else { return }
            if let window = field.window, window.makeFirstResponder(field) {
                if let editor = field.currentEditor() as? NSTextView {
                    applyFocusSelection(selection, to: editor)
                }
                lastFocusRequestID = request.id
                pendingFocusRequestID = nil
                parent.onFocusRequestHandled(request.id)
                return
            }
            guard remainingAttempts > 0 else {
                pendingFocusRequestID = nil
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(10)) { [weak self, weak field] in
                guard let self, let field else { return }
                self.attemptFocus(request, for: field, remainingAttempts: remainingAttempts - 1)
            }
        }

        func applyFocusSelection(_ selection: SearchFocusSelection, to editor: NSTextView) {
            switch selection {
            case .selectAll:
                editor.selectAll(nil)
            case .collapseSelectionToEnd:
                guard editor.selectedRange().length > 0 else { return }
                editor.setSelectedRange(NSRange(
                    location: (editor.string as NSString).length,
                    length: 0
                ))
            }
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            parent.onFocusChange(true)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            parent.onFocusChange(false)
        }

        func controlTextDidChange(_ notification: Notification) {
            guard !isApplyingPresentation,
                  let editor = notification.userInfo?["NSFieldEditor"] as? NSTextView else { return }
            let value = editor.string
            completionSuppressedForText = replacementWasDeletion ? value : nil
            replacementWasDeletion = false
            lastPresentedText = value
            lastPresentedCompletionTitle = nil
            parent.onChange(value)
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            shouldChangeCharactersIn range: NSRange,
            replacementString string: String?
        ) -> Bool {
            replacementWasDeletion = string?.isEmpty ?? true
            return true
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                parent.onSubmit()
            case #selector(NSResponder.moveUp(_:)):
                parent.onMove(-1)
            case #selector(NSResponder.moveDown(_:)):
                parent.onMove(1)
            case #selector(NSResponder.cancelOperation(_:)):
                completionSuppressedForText = nil
                parent.onEscape()
            case #selector(NSResponder.deleteBackward(_:)), #selector(NSResponder.deleteForward(_:)):
                replacementWasDeletion = true
                return false
            default:
                return false
            }
            return true
        }
    }
}

struct SearchFieldCompletion: Equatable {
    let string: String
    let completionRange: NSRange?

    static func presentation(typedText: String, completionTitle: String?) -> SearchFieldCompletion {
        guard let completionTitle else {
            return SearchFieldCompletion(string: typedText, completionRange: nil)
        }

        let typedLength = (typedText as NSString).length
        let title = completionTitle as NSString
        guard typedLength < title.length else {
            return SearchFieldCompletion(string: typedText, completionRange: nil)
        }

        let suffix = title.substring(from: typedLength)
        let string = typedText + suffix
        return SearchFieldCompletion(
            string: string,
            completionRange: NSRange(location: typedLength, length: (suffix as NSString).length)
        )
    }
}
