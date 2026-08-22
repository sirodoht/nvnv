import AppKit
import NVNVCore
import SwiftUI
import Testing
@testable import nvnv

@MainActor
@Suite("Plain text editor find", .serialized)
struct PlainTextEditorFindTests {
    @Test func usesAnInlineIncrementalFindBarAndImportsTheVaultQuery() async throws {
        let findPasteboard = NSPasteboard(name: .find)
        let previousFindString = findPasteboard.string(forType: .string)
        defer {
            findPasteboard.clearContents()
            if let previousFindString {
                findPasteboard.setString(previousFindString, forType: .string)
            }
        }

        let note = Note(title: "Find", body: "needle and another needle", filename: "Find.txt")
        let findSession = EditorFindSession()
        let hostingView = NSHostingView(rootView: makeEditor(
            note: note, seed: "  \"needle\"  ", command: nil, generation: 0,
            findSession: findSession
        ))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        defer { window.close() }
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        window.layoutIfNeeded()
        try await settleUI()

        let textView = try #require(firstSubview(of: SessionTextView.self, in: hostingView))
        let scrollView = try #require(textView.enclosingScrollView)
        #expect(textView.usesFindBar)
        #expect(!textView.usesFindPanel)
        #expect(textView.isIncrementalSearchingEnabled)

        hostingView.rootView = makeEditor(
            note: note, seed: "  \"needle\"  ", command: .find, generation: 1,
            findSession: findSession
        )
        try await settleUI()

        #expect(scrollView.isFindBarVisible)
        #expect(findPasteboard.string(forType: .string) == "needle")
    }

    @Test func nextMatchOpensAHiddenBarWithoutOverwritingAManualFindTerm() async throws {
        let findPasteboard = NSPasteboard(name: .find)
        let previousFindString = findPasteboard.string(forType: .string)
        defer {
            findPasteboard.clearContents()
            if let previousFindString {
                findPasteboard.setString(previousFindString, forType: .string)
            }
        }

        let note = Note(title: "Find", body: "needle manual manual", filename: "Find.txt")
        let findSession = EditorFindSession()
        let hostingView = NSHostingView(rootView: makeEditor(
            note: note, seed: "needle", command: nil, generation: 0,
            findSession: findSession
        ))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        defer { window.close() }
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        window.layoutIfNeeded()
        try await settleUI()

        let textView = try #require(firstSubview(of: SessionTextView.self, in: hostingView))
        let scrollView = try #require(textView.enclosingScrollView)
        hostingView.rootView = makeEditor(
            note: note, seed: "needle", command: .find, generation: 1,
            findSession: findSession
        )
        try await settleUI()

        findPasteboard.clearContents()
        findPasteboard.setString("manual", forType: .string)
        scrollView.isFindBarVisible = false
        hostingView.rootView = makeEditor(
            note: note, seed: "needle", command: .findNext, generation: 2,
            findSession: findSession
        )
        try await settleUI()

        #expect(scrollView.isFindBarVisible)
        #expect(findPasteboard.string(forType: .string) == "manual")
    }

    @Test func replaceAllUndoAndRedoKeepTheModelFacingBodySynchronized() async throws {
        let findPasteboard = NSPasteboard(name: .find)
        let previousFindString = findPasteboard.string(forType: .string)
        defer {
            findPasteboard.clearContents()
            if let previousFindString {
                findPasteboard.setString(previousFindString, forType: .string)
            }
        }

        let originalBody = "needle and needle"
        let replacedBody = "found and found"
        let note = Note(title: "Replace", body: originalBody, filename: "Replace.txt")
        let findSession = EditorFindSession()
        let undoRegistry = EditorUndoRegistry()
        var modelFacingBody = originalBody
        let hostingView = NSHostingView(rootView: makeEditor(
            note: note, seed: "needle", command: nil, generation: 0,
            findSession: findSession, undoRegistry: undoRegistry,
            onChange: { modelFacingBody = $0 }
        ))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        defer { window.close() }
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        window.layoutIfNeeded()
        try await settleUI()

        let textView = try #require(firstSubview(of: SessionTextView.self, in: hostingView))
        let scrollView = try #require(textView.enclosingScrollView)
        hostingView.rootView = makeEditor(
            note: note, seed: "needle", command: .find, generation: 1,
            findSession: findSession, undoRegistry: undoRegistry,
            onChange: { modelFacingBody = $0 }
        )
        try await settleUI()

        let findBar = try #require(scrollView.findBarView)
        let replaceDisclosure = try #require(
            firstSubview(of: NSButton.self, in: findBar) { $0.title == "Replace" }
        )
        replaceDisclosure.performClick(nil)
        try await settleUI()
        let replacementField = try #require(
            firstSubview(of: NSTextField.self, in: findBar) { !($0 is NSSearchField) }
        )
        replacementField.stringValue = "found"
        let replaceAll = NSMenuItem()
        replaceAll.tag = Int(NSFindPanelAction.replaceAll.rawValue)
        textView.performFindPanelAction(replaceAll)
        try await settleUI()

        #expect(textView.string == replacedBody)
        #expect(modelFacingBody == replacedBody)

        textView.undo(nil)
        try await settleUI()

        #expect(textView.string == originalBody)
        #expect(modelFacingBody == originalBody)

        textView.redo(nil)
        try await settleUI()

        #expect(textView.string == replacedBody)
        #expect(modelFacingBody == replacedBody)
    }

    private func makeEditor(
        note: Note, seed: String, command: EditorCommand?, generation: Int,
        findSession: EditorFindSession,
        undoRegistry: EditorUndoRegistry = EditorUndoRegistry(),
        onChange: @escaping (String) -> Void = { _ in }
    ) -> PlainTextEditor {
        PlainTextEditor(
            note: note,
            editable: true,
            matchRanges: [],
            findSeedText: seed,
            fontName: "",
            fontSize: 13,
            softTabs: true,
            tabWidth: 4,
            tabIndents: true,
            focusRequest: nil,
            command: command,
            commandGeneration: generation,
            undoInvalidationGeneration: 0,
            undoRegistry: undoRegistry,
            findSession: findSession,
            onChange: onChange,
            onSelectionChange: { _ in },
            onEditingEnded: {},
            onFocus: {},
            onFocusRequestHandled: { _ in }
        )
    }

    private func settleUI() async throws {
        for _ in 0..<4 {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    private func firstSubview<T: NSView>(
        of type: T.Type, in view: NSView, where predicate: (T) -> Bool = { _ in true }
    ) -> T? {
        if let match = view as? T, predicate(match) { return match }
        for subview in view.subviews {
            if let match = firstSubview(of: type, in: subview, where: predicate) { return match }
        }
        return nil
    }
}
