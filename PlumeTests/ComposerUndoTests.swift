import AppKit
import Testing

@testable import Plume

/// The composer driven as a real `NSTextView`: typing, the markdown input
/// rules, the list keys, ⌘B, paste, and what ⌘Z does to each of them.
///
/// Undo is the reason this suite runs against a live view rather than the pure
/// rule modules. `NSUndoManager` comes from the window, and whether a
/// conversion lands as its own undoable edit is a fact about how the view
/// applies it, not about what the rules decided.
@MainActor
struct ComposerUndoTests {
    /// A hosted composer plus the window its undo manager comes from. The
    /// window is closed by `ComposerUndoTests` on the way out of each test.
    private struct Composer {
        let window: NSWindow
        let host: ScrollableComposerTextView
        let delegate: TypingAttributesDelegate
        var view: ComposerNSTextView { host.composerTextView }

        func type(_ text: String) {
            for character in text {
                startEvent()
                view.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
                endEvent()
            }
        }

        /// Stands in for one key press. `NSUndoManager` normally closes a
        /// group at the end of each event, but that is driven by
        /// `NSApplication`'s event loop, which a unit test has none of — so
        /// the harness opens and closes the groups itself.
        func startEvent() {
            window.undoManager?.beginUndoGrouping()
        }

        func endEvent() {
            guard let manager = window.undoManager, manager.groupingLevel > 0 else { return }
            manager.endUndoGrouping()
        }

        private func event(_ body: () -> Void) {
            startEvent()
            body()
            endEvent()
        }

        func newline() { event { view.insertNewline(nil) } }
        func tab() { event { view.insertTab(nil) } }
        func backtab() { event { view.insertBacktab(nil) } }
        func backspace() { event { view.deleteBackward(nil) } }
        func deleteWord() { event { view.deleteWordBackward(nil) } }
        func toggle(_ inline: ComposerInlineStyle) { event { view.toggleInline(inline) } }
        func paste(from pasteboard: NSPasteboard) -> Bool {
            var accepted = false
            event { accepted = view.readSelection(from: pasteboard) }
            return accepted
        }

        func kind(at location: Int) -> ComposerBlockKind? {
            guard let storage = view.textStorage, storage.length > location else {
                return view.typingAttributes[.plumeBlock] as? ComposerBlockKind
            }
            return storage.attribute(.plumeBlock, at: location, effectiveRange: nil) as? ComposerBlockKind
        }

        func inline(at location: Int) -> ComposerInlineStyle {
            guard let storage = view.textStorage, storage.length > location else { return [] }
            return (storage.attribute(.plumeInline, at: location, effectiveRange: nil) as? ComposerInlineStyle) ?? []
        }

        func undo() { window.undoManager?.undo() }
        func redo() { window.undoManager?.redo() }
        func close() {
            window.contentView = nil
            window.close()
        }
    }

    /// Production wires this to `MarkdownComposerTextView.Coordinator`; the
    /// rules themselves live in `desiredTypingAttributes()`, which is what
    /// both paths call.
    @MainActor
    final class TypingAttributesDelegate: NSObject, NSTextViewDelegate {
        func textView(
            _ view: NSTextView,
            shouldChangeTypingAttributes oldTypingAttributes: [String: Any],
            toAttributes newTypingAttributes: [NSAttributedString.Key: Any]
        ) -> [NSAttributedString.Key: Any] {
            (view as? ComposerNSTextView)?.desiredTypingAttributes() ?? newTypingAttributes
        }
    }

    private func makeComposer() -> Composer {
        let host = ScrollableComposerTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        // Without this an ARC-held window is released twice — once by
        // `close()`, once by the test — and the pool pop segfaults.
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.undoManager?.groupsByEvent = false
        let delegate = TypingAttributesDelegate()
        host.composerTextView.delegate = delegate
        host.composerTextView.loadDocument(NSAttributedString(string: ""))
        window.makeFirstResponder(host.composerTextView)
        return Composer(window: window, host: host, delegate: delegate)
    }

    // MARK: - Plain typing

    @Test func undoRestoresADeletedWordAndRedoRemovesItAgain() {
        let composer = makeComposer()
        defer { composer.close() }

        composer.type("hello there")
        composer.deleteWord()
        #expect(composer.view.string == "hello ")

        composer.undo()
        #expect(composer.view.string == "hello there")

        composer.redo()
        #expect(composer.view.string == "hello ")
    }

    // MARK: - Block rules

    @Test func bulletConversionUndoesToTheLiteralMarker() {
        let composer = makeComposer()
        defer { composer.close() }

        composer.type("- ")
        #expect(composer.view.string == "")
        #expect(composer.view.typingAttributes[.plumeBlock] as? ComposerBlockKind == .bullet(depth: 0))

        composer.undo()
        #expect(composer.view.string == "- ")
        #expect(composer.kind(at: 0) == .paragraph)

        composer.redo()
        #expect(composer.view.string == "")
    }

    @Test func typingAfterAConversionUndoesWithoutSwallowingIt() {
        let composer = makeComposer()
        defer { composer.close() }

        composer.type("- item")
        #expect(composer.view.string == "item")
        #expect(composer.kind(at: 0) == .bullet(depth: 0))

        // One group per character here — the harness stands in for the event
        // loop, which is also what coalesces a typing run in the real app.
        for _ in "item" { composer.undo() }
        #expect(composer.view.string == "")
        #expect(composer.kind(at: 0) == .bullet(depth: 0))

        composer.undo()
        #expect(composer.view.string == "- ")
        #expect(composer.kind(at: 0) == .paragraph)
    }

    @Test func headingConvertsAndUndoesToItsLiteralHashes() {
        let composer = makeComposer()
        defer { composer.close() }

        composer.type("## Title")
        #expect(composer.view.string == "Title")
        #expect(composer.kind(at: 0) == .heading(2))

        for _ in "Title" { composer.undo() }
        composer.undo()
        #expect(composer.view.string == "## ")
        #expect(composer.kind(at: 0) == .paragraph)
    }

    // MARK: - Inline rules

    @Test func boldConvertsAndUndoesToItsLiteralAsterisks() {
        let composer = makeComposer()
        defer { composer.close() }

        composer.type("**x**")
        #expect(composer.view.string == "x")
        #expect(composer.inline(at: 0) == .bold)

        composer.undo()
        #expect(composer.view.string == "**x**")
        #expect(composer.inline(at: 2) == [])
    }

    @Test func inlineCodeConvertsAndDoesNotExtendAtItsTrailingEdge() {
        let composer = makeComposer()
        defer { composer.close() }

        composer.type("run `git` now")
        #expect(composer.view.string == "run git now")
        #expect(composer.inline(at: 4) == .code)
        // The chip stops where it stops: typing after it is prose again.
        #expect(composer.inline(at: 8) == [])
    }

    // MARK: - List keys

    @Test func returnContinuesABulletList() {
        let composer = makeComposer()
        defer { composer.close() }

        composer.type("- first")
        composer.newline()
        composer.type("second")

        #expect(composer.view.string == "first\nsecond")
        #expect(composer.kind(at: 0) == .bullet(depth: 0))
        #expect(composer.kind(at: 6) == .bullet(depth: 0))
    }

    @Test func returnOnAnEmptyBulletLeavesTheList() {
        let composer = makeComposer()
        defer { composer.close() }

        composer.type("- first")
        composer.newline()
        composer.newline()
        composer.type("prose")

        #expect(composer.view.string == "first\nprose")
        #expect(composer.kind(at: 6) == .paragraph)
    }

    @Test func tabIndentsAndShiftTabOutdentsAListItem() {
        let composer = makeComposer()
        defer { composer.close() }

        composer.type("- first")
        composer.newline()
        composer.type("second")
        composer.tab()
        #expect(composer.kind(at: 6) == .bullet(depth: 1))

        composer.backtab()
        #expect(composer.kind(at: 6) == .bullet(depth: 0))
    }

    @Test func backspaceAtAnItemStartRemovesTheMarker() {
        let composer = makeComposer()
        defer { composer.close() }

        composer.type("- item")
        composer.view.setSelectedRange(NSRange(location: 0, length: 0))
        composer.backspace()

        #expect(composer.view.string == "item")
        #expect(composer.kind(at: 0) == .paragraph)
    }

    @Test func numberedListsCountUpAcrossReturns() {
        let composer = makeComposer()
        defer { composer.close() }

        composer.type("1. one")
        composer.newline()
        composer.type("two")

        #expect(composer.view.string == "one\ntwo")
        #expect(composer.kind(at: 4) == .numbered(depth: 0, number: 2))
    }

    // MARK: - Code blocks

    @Test func aFenceOpensACodeBlockOnTheFollowingReturn() {
        let composer = makeComposer()
        defer { composer.close() }

        composer.type("```swift")
        // The fence characters are still literal until Return.
        #expect(composer.view.string == "```swift")

        composer.newline()
        #expect(composer.view.string == "")
        composer.type("let x = 1")
        #expect(composer.kind(at: 0) == .codeBlock(language: "swift", blockID: composer.kind(at: 0)!.blockID))
    }

    @Test func returnOnAnEmptyLastLineLeavesTheCodeBlock() {
        let composer = makeComposer()
        defer { composer.close() }

        composer.type("```")
        composer.newline()
        composer.type("code")
        composer.newline()
        composer.newline()
        composer.type("prose")

        #expect(composer.view.string == "code\nprose")
        #expect(composer.kind(at: 5) == .paragraph)
    }

    // MARK: - ⌘B

    @Test func toggleBoldOnASelectionIsUndoable() {
        let composer = makeComposer()
        defer { composer.close() }

        composer.type("hello")
        composer.view.setSelectedRange(NSRange(location: 0, length: 5))
        composer.toggle(.bold)
        #expect(composer.inline(at: 0) == .bold)

        composer.undo()
        #expect(composer.inline(at: 0) == [])
        #expect(composer.view.string == "hello")
    }

    // MARK: - Pasteboard

    @Test func pastingLiteralMarkdownStaysLiteral() {
        let composer = makeComposer()
        defer { composer.close() }

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.ryanmoelter.Plume.tests.literal"))
        pasteboard.clearContents()
        pasteboard.setString("**x** and ~/.claude/*.json", forType: .string)

        #expect(composer.paste(from: pasteboard))
        #expect(composer.view.string == "**x** and ~/.claude/*.json")
        #expect(composer.inline(at: 2) == [])
        #expect(composer.view.currentMarkdown == "**x** and ~/.claude/*.json")
    }

    @Test func aCopiedSliceKeepsItsFormattingThroughThePrivateType() {
        let composer = makeComposer()
        defer { composer.close() }

        composer.type("**x**")
        composer.view.setSelectedRange(NSRange(location: 0, length: 1))
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.ryanmoelter.Plume.tests.slice"))
        pasteboard.clearContents()
        #expect(composer.view.writeSelection(to: pasteboard, type: ComposerPasteboard.type))

        composer.view.setSelectedRange(NSRange(location: 1, length: 0))
        #expect(composer.paste(from: pasteboard))
        #expect(composer.view.string == "xx")
        #expect(composer.inline(at: 1) == .bold)
    }

    // MARK: - Loading a document

    /// One window, one undo manager, and a composer per chat tab: loading a
    /// document may only drop the undo actions of the view it loads into.
    @Test func loadingADocumentLeavesAnotherComposersUndoAlone() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.undoManager?.groupsByEvent = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        let typed = ScrollableComposerTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let loaded = ScrollableComposerTextView(frame: NSRect(x: 0, y: 200, width: 400, height: 200))
        container.addSubview(typed)
        container.addSubview(loaded)
        window.contentView = container
        defer {
            window.contentView = nil
            window.close()
        }
        typed.composerTextView.loadDocument(NSAttributedString(string: ""))
        loaded.composerTextView.loadDocument(NSAttributedString(string: ""))
        window.makeFirstResponder(typed.composerTextView)

        let manager = try #require(window.undoManager)
        manager.beginUndoGrouping()
        typed.composerTextView.insertText("hello", replacementRange: NSRange(location: NSNotFound, length: 0))
        manager.endUndoGrouping()
        #expect(manager.canUndo)

        loaded.composerTextView.loadDocument(NSAttributedString(string: "elsewhere"))
        #expect(manager.canUndo, "loading one composer must not clear another's undo")
        manager.undo()
        #expect(typed.composerTextView.string == "")

        // AppKit registers a text edit against the text storage, which each
        // composer has its own of — the other half of what makes scoping the
        // removal to one composer work.
        manager.beginUndoGrouping()
        typed.composerTextView.insertText("again", replacementRange: NSRange(location: NSNotFound, length: 0))
        manager.endUndoGrouping()
        typed.composerTextView.loadDocument(NSAttributedString(string: ""))
        #expect(!manager.canUndo, "a composer's own load clears its own undo")
    }

    // MARK: - Serialization

    @Test func aDocumentWithEveryConstructRoundTripsToMarkdown() {
        let composer = makeComposer()
        defer { composer.close() }

        let markdown = """
        # Title

        A line with `inline code` in it.

        - first
        - second

        ```swift
        let x = 1
        ```
        """
        composer.view.loadDocument(
            ComposerDocument.attributedString(markdown: markdown, style: composer.view.style)
        )
        #expect(composer.view.currentMarkdown == markdown)
        // Nothing structural is in the characters themselves.
        #expect(!composer.view.string.contains("#"))
        #expect(!composer.view.string.contains("`"))
    }
}
