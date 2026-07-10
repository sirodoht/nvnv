import AppKit
import NVNVCore
import SwiftUI

@MainActor
final class EditorUndoRegistry {
    private var managers: [UUID: UndoManager] = [:]
    func manager(for id: UUID) -> UndoManager {
        if let manager = managers[id] { return manager }
        let manager = UndoManager()
        managers[id] = manager
        return manager
    }
    func clear(_ id: UUID) { managers[id]?.removeAllActions() }
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
    let focusGeneration: Int
    let command: EditorCommand?
    let commandGeneration: Int
    let undoRegistry: EditorUndoRegistry
    let onChange: (String) -> Void
    let onSelectionChange: (NSRange) -> Void

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
        text.textContainerInset = NSSize(width: 22, height: 18)
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
        text.sessionUndoManager = undoRegistry.manager(for: note.id)
        let chosen = fontName.isEmpty ? nil : NSFont(name: fontName, size: fontSize)
        text.font = chosen ?? NSFont.systemFont(ofSize: fontSize)
        if text.string != note.body {
            coordinator.pushingState = true
            text.string = note.body
            text.setSelectedRange(note.clampedSelection)
            coordinator.pushingState = false
        }
        applyHighlights(text)
        if coordinator.lastFocusGeneration != focusGeneration {
            coordinator.lastFocusGeneration = focusGeneration
            DispatchQueue.main.async { text.window?.makeFirstResponder(text) }
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
        var lastFocusGeneration = -1
        var lastCommandGeneration = -1

        init(parent: PlainTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard !pushingState, let text = notification.object as? NSTextView else { return }
            parent.onChange(text.string)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !pushingState, let text = notification.object as? NSTextView else { return }
            parent.onSelectionChange(text.selectedRange())
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
            guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return }
            let text = textView.string as NSString
            let safe = min(max(location, 0), max(text.length - 1, 0))
            guard let result = detector.matches(in: textView.string, range: NSRange(location: 0, length: text.length))
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
