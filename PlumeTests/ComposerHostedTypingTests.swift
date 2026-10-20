import AppKit
import SwiftUI
import Testing

@testable import Plume

/// The markdown editing keys reached the way a keyboard reaches them: key
/// events through `keyDown` into the real `MarkdownComposerTextView` hosted in
/// a window, with its binding writing back into SwiftUI state that the next
/// update pass reads again.
@MainActor
struct ComposerHostedTypingTests {
    private final class Draft {
        var markdown = ""
    }

    private struct Host: View {
        let draft: Draft
        @State private var text = ""
        @State private var isFocused = true

        var body: some View {
            MarkdownComposerTextView(
                text: Binding(get: { text }, set: { text = $0; draft.markdown = $0 }),
                placeholder: "",
                fontSize: 13,
                isFocused: $isFocused,
                sendKey: .commandReturn,
                onSend: {}
            )
            .frame(width: 400, height: 200)
        }
    }

    private struct Harness {
        let window: NSWindow
        let view: ComposerNSTextView
        let draft: Draft

        /// Each key press gets its own main-queue turn, the way the event loop
        /// delivers them, so SwiftUI's update pass runs between keystrokes.
        func type(_ text: String) async throws {
            for character in text {
                let keyCode: UInt16 = switch character {
                case "\r": 36
                case "\t": 48
                case "\u{7F}": 51
                default: 0
                }
                try await press(String(character), keyCode: keyCode)
            }
        }

        func press(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) async throws {
            let event = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: keyCode
            ))
            try await handle { view.keyDown(with: event) }
        }

        /// Runs one event in its own undo group. The app's event loop closes
        /// the undo manager's per-event group after every event, and a test's
        /// run loop never does, so the harness turns `groupsByEvent` off and
        /// groups by hand.
        func handle(_ event: () -> Void) async throws {
            let manager = try #require(view.undoManager)
            manager.beginUndoGrouping()
            event()
            manager.endUndoGrouping()
            try await Task.sleep(for: .milliseconds(20))
        }

        func shiftTab() async throws {
            try await press("\u{19}", keyCode: 48, modifiers: .shift)
        }

        func left() async throws {
            try await press(String(UnicodeScalar(NSLeftArrowFunctionKey)!), keyCode: 123, modifiers: [.numericPad, .function])
        }

        func click(at point: NSPoint) async throws {
            let location = view.convert(point, to: nil)
            let event = try #require(NSEvent.mouseEvent(
                with: .leftMouseDown, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ))
            try await handle { view.mouseDown(with: event) }
        }

        func close() {
            window.contentView = nil
            window.close()
        }
    }

    private static func makeHarness() async throws -> Harness {
        let draft = Draft()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let content = NSHostingView(rootView: Host(draft: draft))
        window.contentView = content
        content.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        let view = try #require(ViewFinder.first(ComposerNSTextView.self, in: content))
        window.makeFirstResponder(view)
        view.undoManager?.groupsByEvent = false
        return Harness(window: window, view: view, draft: draft)
    }

    @Test(arguments: [
        (keys: "- a\rb", expected: "- a\n- b"),
        (keys: "1. a\rb", expected: "1. a\n2. b"),
        (keys: "- a\r\r", expected: "- a\n"),
        (keys: "- a\r\tb", expected: "- a\n  - b"),
        (keys: "1. a\r\tb", expected: "1. a\n   1. b"),
        (keys: "- \u{7F}", expected: ""),
        (keys: "> a\rb", expected: "> a\n> b"),
        (keys: "```\r- a\r", expected: "```\n- a\n"),
        (keys: "- a\rx b", expected: "- [ ] a\n- [ ] b"),
        (keys: "1. a\r- b", expected: "- a\n- b"),
        (keys: "[ ] a", expected: "- [ ] a"),
    ])
    func editingKeys(keys: String, expected: String) async throws {
        let harness = try await Self.makeHarness()
        defer { harness.close() }

        try await harness.type(keys)

        #expect(harness.view.string == expected)
        #expect(harness.draft.markdown == expected)
    }

    @Test func shiftTabOutdents() async throws {
        let harness = try await Self.makeHarness()
        defer { harness.close() }

        try await harness.type("- a\r\t")
        try await harness.shiftTab()
        try await harness.type("b")

        #expect(harness.draft.markdown == "- a\n- b")
    }

    @Test func caretSkipsAHiddenBullet() async throws {
        let harness = try await Self.makeHarness()
        defer { harness.close() }

        try await harness.type("a\r- b")
        try await harness.left()
        #expect(harness.view.selectedRange().location == 4)
        try await harness.left()
        #expect(harness.view.selectedRange().location == 1)
    }

    @Test func aListReturnIsOneUndoStep() async throws {
        let harness = try await Self.makeHarness()
        defer { harness.close() }

        try await harness.type("- a\r")
        #expect(harness.view.string == "- a\n- ")
        harness.view.undoManager?.undo()

        #expect(harness.view.string == "- a")
    }

    @Test func clickingACheckboxTogglesItAsOneUndoStep() async throws {
        let harness = try await Self.makeHarness()
        defer { harness.close() }
        try await harness.type("- [ ] task")
        let metrics = try #require(harness.view.markdownMetrics)
        let box = try #require(ComposerDecorations.rects(in: harness.view, metrics: metrics).checkboxes.first)

        try await harness.click(at: NSPoint(x: box.rect.midX, y: box.rect.midY))
        #expect(harness.draft.markdown == "- [x] task")

        harness.view.undoManager?.undo()
        #expect(harness.view.string == "- [ ] task")
    }

    @Test func typingInAScrolledComposerKeepsItsPlace() async throws {
        let harness = try await Self.makeHarness()
        defer { harness.close() }
        try await harness.type("intro\r- one\rtwo\rthree\rfour\r\r1. a\rb\rc\rd\r\r> q\rr\rs\r\rpara\rpara\rpara\rlast")
        let clip = try #require(harness.view.enclosingScrollView?.contentView)
        let scrolledTo = clip.bounds.origin.y
        #expect(scrolledTo > 0)

        try await harness.type(" \u{7F}")

        #expect(clip.bounds.origin.y == scrolledTo)
    }

    @Test(arguments: ["para", "- item"])
    func aNewEmptyLastLineScrollsIntoView(lastLine: String) async throws {
        let harness = try await Self.makeHarness()
        defer { harness.close() }
        try await harness.type("a\rb\rc\rd\re\rf\rg\rh\ri\rj\r" + lastLine)
        let clip = try #require(harness.view.enclosingScrollView?.contentView)

        try await harness.type("\r")

        #expect(clip.bounds.maxY >= harness.view.frame.maxY - 0.5, "\(clip.bounds) vs \(harness.view.frame)")
    }

    @Test func aPasteWithIndentTabsIsOneUndoStep() async throws {
        let harness = try await Self.makeHarness()
        defer { harness.close() }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ComposerHostedTypingTests.\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("- a\n\t- b", forType: .string)

        try await harness.handle { _ = harness.view.readSelection(from: pasteboard, type: .string) }
        #expect(harness.draft.markdown == "- a\n    - b")

        harness.view.undoManager?.undo()
        #expect(harness.view.string == "")
    }

    @Test func aPasteIsOneUndoStep() async throws {
        let harness = try await Self.makeHarness()
        defer { harness.close() }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ComposerHostedTypingTests.\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("- a\n- b", forType: .string)

        try await harness.handle { _ = harness.view.readSelection(from: pasteboard, type: .string) }
        #expect(harness.draft.markdown == "- a\n- b")

        harness.view.undoManager?.undo()
        #expect(harness.view.string == "")
    }
}
