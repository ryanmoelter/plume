import AppKit
import SwiftUI
import Testing

@testable import Plume

/// Return and Esc in a hosted composer, typed key by key the way
/// `ComposerHostedTypingTests` types. With a mention row to pick, Return
/// inserts the reference. With the menu only searching, Return closes it and
/// types a space whichever key sends, and ⌘↩ still sends. Esc closes the menu
/// for that token without reaching the interrupt, and only the next Esc
/// interrupts.
@MainActor
struct ComposerMentionHostedTests {
    @Observable
    fileprivate final class State {
        var markdown = ""
        var pendingCaret: Int?
        var sends = 0
        var escapes = 0
    }

    private struct Host: View {
        let state: State
        let router: ComposerAutocompleteRouter
        let sendKey: ComposerSendKey
        @SwiftUI.State private var isFocused = true

        var body: some View {
            MarkdownComposerTextView(
                text: Binding(get: { state.markdown }, set: { state.markdown = $0 }),
                placeholder: "",
                fontSize: 13,
                isFocused: $isFocused,
                sendKey: sendKey,
                onSend: { state.sends += 1 },
                onCaretChange: { location in
                    router.mention.update(
                        text: state.markdown,
                        caretLocation: location,
                        directory: "/repo",
                        isCommandMode: false
                    )
                },
                pendingCaretLocation: Binding(get: { state.pendingCaret }, set: { state.pendingCaret = $0 }),
                autocompleteHandler: router,
                onEscape: { _ in
                    state.escapes += 1
                    return true
                }
            )
            .frame(width: 400, height: 200)
        }
    }

    private struct Harness {
        let window: NSWindow
        let view: ComposerNSTextView
        let state: State

        func type(_ text: String) async throws {
            for character in text {
                try await press(String(character), keyCode: character == "\r" ? 36 : 0)
            }
        }

        func escape() async throws {
            try await press("\u{1b}", keyCode: 53)
        }

        func press(_ characters: String, keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags = []) async throws {
            let event = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifierFlags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: keyCode
            ))
            view.keyDown(with: event)
            try await Task.sleep(for: .milliseconds(20))
        }

        func close() {
            window.contentView = nil
            window.close()
        }
    }

    private static func makeHarness(
        router: ComposerAutocompleteRouter,
        sendKey: ComposerSendKey = .returnKey
    ) async throws -> Harness {
        let state = State()
        router.mention.onAccept = { accepted in
            state.markdown = accepted.text
            state.pendingCaret = accepted.caretLocation
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let content = NSHostingView(rootView: Host(state: state, router: router, sendKey: sendKey))
        window.contentView = content
        content.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        let view = try #require(ViewFinder.first(ComposerNSTextView.self, in: content))
        window.makeFirstResponder(view)
        return Harness(window: window, view: view, state: state)
    }

    @Test func returnAcceptsTheMentionInsteadOfSending() async throws {
        let sources = FakeMentionSources()
        let issue = MentionFixtures.issue("DROID-123", "Fix the text layout")
        sources.linearAnswer = { LinearMentionMatcher.matches($0, in: [issue]) }
        let router = ComposerAutocompleteRouter(
            mention: MentionAutocompleteController(sources: sources, sleep: { _ in }, homeDirectory: "/Users/test")
        )
        let harness = try await Self.makeHarness(router: router)
        defer { harness.close() }

        try await harness.type("@dro layout")
        await router.mention.settled()
        #expect(router.mention.query?.text == "dro layout")
        #expect(router.isShowing)
        try await harness.type("\r")

        let expected = "@DROID-123 "
        #expect(harness.state.markdown == expected)
        #expect(harness.view.string == expected)
        #expect(harness.view.selectedRange().location == (expected as NSString).length)
        #expect(harness.state.sends == 0)
    }

    private static func loadingRouter(_ sources: FakeMentionSources) -> ComposerAutocompleteRouter {
        sources.holdsFiles = true
        return ComposerAutocompleteRouter(
            mention: MentionAutocompleteController(sources: sources, sleep: { _ in }, homeDirectory: "/Users/test")
        )
    }

    @Test(arguments: [ComposerSendKey.returnKey, .commandReturn])
    func returnClosesALoadingMenuAndTypesASpace(sendKey: ComposerSendKey) async throws {
        let sources = FakeMentionSources()
        defer { sources.releaseAll() }
        let router = Self.loadingRouter(sources)
        let harness = try await Self.makeHarness(router: router, sendKey: sendKey)
        defer { harness.close() }

        try await harness.type("@zz")
        #expect(router.mention.isPresented)
        #expect(!router.isShowing)
        try await harness.type("\r")

        #expect(harness.state.markdown == "@zz ")
        #expect(harness.state.sends == 0)
        #expect(!router.mention.isPresented)
        try await harness.type("y")
        #expect(!router.mention.isPresented)
    }

    @Test func commandReturnStillSendsWhileTheMenuIsOnlyLoading() async throws {
        let sources = FakeMentionSources()
        defer { sources.releaseAll() }
        let router = Self.loadingRouter(sources)
        let harness = try await Self.makeHarness(router: router, sendKey: .commandReturn)
        defer { harness.close() }

        try await harness.type("@zz")
        #expect(router.mention.isPresented)
        try await harness.press("\r", keyCode: 36, modifierFlags: .command)

        #expect(harness.state.sends == 1)
        #expect(harness.state.markdown == "@zz")
    }

    @Test func escapeClosesALoadingMenuBeforeInterrupting() async throws {
        let sources = FakeMentionSources()
        defer { sources.releaseAll() }
        let router = Self.loadingRouter(sources)
        let harness = try await Self.makeHarness(router: router)
        defer { harness.close() }

        try await harness.type("@foo")
        #expect(router.mention.isPresented)
        try await harness.escape()

        #expect(harness.state.escapes == 0)
        #expect(!router.mention.isPresented)
        try await harness.type("bar")
        #expect(harness.state.markdown == "@foobar")
        #expect(!router.mention.isPresented)

        try await harness.escape()
        #expect(harness.state.escapes == 1)

        try await harness.type(" @b")
        #expect(router.mention.isPresented)
    }

    @Test func escapeClosesTheMenuWithRowsBeforeInterrupting() async throws {
        let sources = FakeMentionSources()
        let issue = MentionFixtures.issue("DROID-123", "Fix the text layout")
        sources.linearAnswer = { LinearMentionMatcher.matches($0, in: [issue]) }
        let router = ComposerAutocompleteRouter(
            mention: MentionAutocompleteController(sources: sources, sleep: { _ in }, homeDirectory: "/Users/test")
        )
        let harness = try await Self.makeHarness(router: router)
        defer { harness.close() }

        try await harness.type("@dro")
        await router.mention.settled()
        #expect(router.isShowing)
        try await harness.escape()

        #expect(harness.state.escapes == 0)
        #expect(!router.mention.isPresented)
        try await harness.type("i")
        await router.mention.settled()
        #expect(!router.mention.isPresented)
        try await harness.escape()
        #expect(harness.state.escapes == 1)
    }
}
