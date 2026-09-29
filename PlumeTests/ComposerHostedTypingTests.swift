import AppKit
import SwiftUI
import Testing

@testable import Plume

/// The input rules reached the way a keyboard reaches them: key events through
/// `keyDown` and `interpretKeyEvents`, into the real `MarkdownComposerTextView`
/// hosted in a window, with its binding writing back into SwiftUI state that
/// the next update pass reads again.
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
                let event = try #require(NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, characters: String(character), charactersIgnoringModifiers: String(character),
                    isARepeat: false, keyCode: character == "\r" ? 36 : 0
                ))
                view.keyDown(with: event)
                try await Task.sleep(for: .milliseconds(20))
            }
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
        return Harness(window: window, view: view, draft: draft)
    }

    @Test func aTypedBulletMarkerConvertsAndStaysConverted() async throws {
        let harness = try await Self.makeHarness()
        defer { harness.close() }

        try await harness.type("- x")

        #expect(harness.view.string == "x")
        #expect(harness.draft.markdown == "- x")
    }

    @Test func typedBoldDelimitersConvertAndStayConverted() async throws {
        let harness = try await Self.makeHarness()
        defer { harness.close() }

        try await harness.type("**b**")

        #expect(harness.view.string == "b")
        #expect(harness.draft.markdown == "**b**")
    }

    @Test func aTypedFenceOpensACodeBlockOnReturn() async throws {
        let harness = try await Self.makeHarness()
        defer { harness.close() }

        try await harness.type("```\rx")

        #expect(harness.view.string == "x")
        #expect(harness.draft.markdown == "```\nx\n```")
    }
}
