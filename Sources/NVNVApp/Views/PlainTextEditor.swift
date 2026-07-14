import AppKit
import NVNVCore
import SwiftUI

@MainActor
final class EditorUndoRegistry {
    private var managers: [UUID: UndoManager] = [:]
    private var appliedInvalidationGenerations: [UUID: Int] = [:]
    func manager(for id: UUID) -> UndoManager {
        if let manager = managers[id] { return manager }
        let manager = UndoManager()
        managers[id] = manager
        return manager
    }
    func applyInvalidation(for id: UUID, generation: Int) {
        guard generation > appliedInvalidationGenerations[id, default: 0] else { return }
        managers[id]?.removeAllActions()
        appliedInvalidationGenerations[id] = generation
    }
}

private final class SessionTextView: NSTextView {
    var sessionUndoManager: UndoManager?
    override var undoManager: UndoManager? { sessionUndoManager ?? super.undoManager }
}

struct PlainTextEditor: NSViewRepresentable {
    let note: Note
    let editable: Bool
    let matchRanges: [NSRange]
    let fontName: String
    let fontSize: Double
    let softTabs: Bool
    let tabWidth: Int
    let tabIndents: Bool
    let focusRequest: EditorFocusRequest?
    let command: EditorCommand?
    let commandGeneration: Int
    let undoInvalidationGeneration: Int
    let undoRegistry: EditorUndoRegistry
    let onChange: (String) -> Void
    let onSelectionChange: (NSRange) -> Void
    let onEditingEnded: () -> Void
    let onFocusRequestHandled: (UUID) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let text = SessionTextView(frame: .zero)
        text.minSize = NSSize(width: 0, height: 0)
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.textContainerInset = NSSize(width: 10, height: 8)
        text.isRichText = false
        text.importsGraphics = false
        text.allowsUndo = true
        text.isAutomaticLinkDetectionEnabled = true
        text.usesFindPanel = true
        text.isIncrementalSearchingEnabled = true
        text.delegate = context.coordinator
        text.sessionUndoManager = undoRegistry.manager(for: note.id)
        scroll.documentView = text
        configure(text, coordinator: context.coordinator)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? SessionTextView else { return }
        context.coordinator.parent = self
        configure(text, coordinator: context.coordinator)
    }

    private func configure(_ text: SessionTextView, coordinator: Coordinator) {
        text.isEditable = editable
        text.isSelectable = true
        undoRegistry.applyInvalidation(for: note.id, generation: undoInvalidationGeneration)
        text.sessionUndoManager = undoRegistry.manager(for: note.id)
        let chosen = fontName.isEmpty ? nil : NSFont(name: fontName, size: fontSize)
        let desiredFont = chosen ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        if text.font != desiredFont { text.font = desiredFont }
        if text.string != note.body {
            coordinator.pushingState = true
            text.string = note.body
            coordinator.detectLinks(in: text)
            text.setSelectedRange(note.clampedSelection)
            coordinator.pushingState = false
        }
        if coordinator.lastMatchRanges != matchRanges ||
            (!matchRanges.isEmpty && coordinator.lastHighlightedRevision != note.revision) {
            applyHighlights(text)
            coordinator.lastMatchRanges = matchRanges
            coordinator.lastHighlightedRevision = note.revision
        }
        if let focusRequest,
           focusRequest.noteID == note.id,
           coordinator.lastFocusRequestID != focusRequest.id {
            coordinator.requestFocus(focusRequest, for: text)
        } else if focusRequest == nil {
            coordinator.cancelPendingFocus()
        }
        if coordinator.lastCommandGeneration != commandGeneration {
            coordinator.lastCommandGeneration = commandGeneration
            if let command { coordinator.perform(command, in: text) }
        }
    }

    private func applyHighlights(_ text: NSTextView) {
        guard let layout = text.layoutManager else { return }
        let full = NSRange(location: 0, length: (text.string as NSString).length)
        layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: full)
        for range in matchRanges where NSMaxRange(range) <= full.length {
            layout.addTemporaryAttribute(.backgroundColor, value: NSColor.selectedTextBackgroundColor.withAlphaComponent(0.45), forCharacterRange: range)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PlainTextEditor
        var pushingState = false
        var lastFocusRequestID: UUID?
        var pendingFocusRequestID: UUID?
        var lastCommandGeneration: Int
        var lastMatchRanges: [NSRange]?
        var lastHighlightedRevision = -1
        private let supportedURLDetector = SupportedURLDetector()
        private let linkDetector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.link.rawValue
        )

        init(parent: PlainTextEditor) {
            self.parent = parent
            lastCommandGeneration = parent.commandGeneration
        }

        func requestFocus(_ request: EditorFocusRequest, for textView: NSTextView) {
            guard pendingFocusRequestID != request.id else { return }
            pendingFocusRequestID = request.id
            attemptFocus(request, for: textView, remainingAttempts: 30)
        }

        func cancelPendingFocus() {
            pendingFocusRequestID = nil
        }

        private func attemptFocus(
            _ request: EditorFocusRequest, for textView: NSTextView, remainingAttempts: Int
        ) {
            guard pendingFocusRequestID == request.id,
                  parent.focusRequest?.id == request.id else { return }
            if let window = textView.window, window.makeFirstResponder(textView) {
                lastFocusRequestID = request.id
                pendingFocusRequestID = nil
                parent.onFocusRequestHandled(request.id)
                return
            }
            guard remainingAttempts > 0 else {
                // Leave the model request unconsumed so a later representable
                // update can initiate another attempt.
                pendingFocusRequestID = nil
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(10)) { [weak self, weak textView] in
                guard let self, let textView else { return }
                self.attemptFocus(request, for: textView, remainingAttempts: remainingAttempts - 1)
            }
        }

        func textDidChange(_ notification: Notification) {
            guard !pushingState, let text = notification.object as? NSTextView else { return }
            parent.onChange(text.string)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !pushingState, let text = notification.object as? NSTextView else { return }
            parent.onSelectionChange(text.selectedRange())
        }

        func textDidEndEditing(_ notification: Notification) {
            parent.onEditingEnded()
        }

        func detectLinks(in textView: NSTextView) {
            guard let supportedURLDetector, let storage = textView.textStorage else { return }
            let fullRange = NSRange(location: 0, length: (storage.string as NSString).length)
            let matches = supportedURLDetector.matches(in: storage.string)

            storage.beginEditing()
            storage.removeAttribute(.link, range: fullRange)
            for match in matches {
                storage.addAttribute(.link, value: match.url, range: match.range)
            }
            storage.endEditing()
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard parent.editable else { return false }
            if commandSelector == #selector(NSResponder.insertNewline(_:)), textView.selectedRange().length == 0 {
                let change = TextTransforms.newlineInsertion(text: textView.string, caret: textView.selectedRange().location)
                textView.insertText(change.replacement, replacementRange: change.range)
                return true
            }
            if commandSelector == #selector(NSResponder.insertTab(_:)), parent.tabIndents {
                applyIndent(textView, outdent: false)
                return true
            }
            if commandSelector == #selector(NSResponder.insertBacktab(_:)), parent.tabIndents {
                applyIndent(textView, outdent: true)
                return true
            }
            return false
        }

        func perform(_ command: EditorCommand, in textView: NSTextView) {
            switch command {
            case .indent: applyIndent(textView, outdent: false)
            case .outdent: applyIndent(textView, outdent: true)
            case .find: performFind(.showFindPanel, in: textView)
            case .findNext: performFind(.next, in: textView)
            case .findPrevious: performFind(.previous, in: textView)
            case .openURL: openURL(at: textView.selectedRange().location, in: textView)
            }
        }

        private func applyIndent(_ textView: NSTextView, outdent: Bool) {
            let oldText = textView.string
            let oldSelection = textView.selectedRange()
            let transformed = outdent
                ? TextTransforms.outdent(text: oldText, selection: oldSelection, tabWidth: parent.tabWidth)
                : TextTransforms.indent(text: oldText, selection: oldSelection, softTabs: parent.softTabs, tabWidth: parent.tabWidth)
            replaceAll(textView, text: transformed.0, selection: transformed.1, inverseText: oldText, inverseSelection: oldSelection)
            textView.undoManager?.setActionName(outdent ? "Outdent" : "Indent")
        }

        private func replaceAll(
            _ textView: NSTextView, text: String, selection: NSRange,
            inverseText: String? = nil, inverseSelection: NSRange? = nil
        ) {
            let priorText = inverseText ?? textView.string
            let priorSelection = inverseSelection ?? textView.selectedRange()
            textView.undoManager?.registerUndo(withTarget: self) { coordinator in
                coordinator.replaceAll(textView, text: priorText, selection: priorSelection)
            }
            pushingState = true
            textView.string = text
            textView.setSelectedRange(selection)
            pushingState = false
            parent.onChange(text)
            parent.onSelectionChange(selection)
        }

        private func performFind(_ action: NSFindPanelAction, in textView: NSTextView) {
            let sender = NSMenuItem()
            sender.tag = Int(action.rawValue)
            textView.performFindPanelAction(sender)
        }

        private func openURL(at location: Int, in textView: NSTextView) {
            guard let linkDetector else { return }
            let text = textView.string as NSString
            let safe = min(max(location, 0), max(text.length - 1, 0))
            guard let result = linkDetector.matches(in: textView.string, range: NSRange(location: 0, length: text.length))
                .first(where: { NSLocationInRange(safe, $0.range) }), let url = result.url else { return }
            let known = ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "")
            if !known {
                let alert = NSAlert()
                alert.messageText = "Open an unfamiliar URL scheme?"
                alert.informativeText = url.absoluteString
                alert.addButton(withTitle: "Open")
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
            }
            NSWorkspace.shared.open(url)
        }
    }
}
