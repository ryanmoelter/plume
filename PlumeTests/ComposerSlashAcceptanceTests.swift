import AppKit
import SwiftUI
import Testing

@testable import Plume

/// Accepting a slash-command suggestion, which reaches the text view a turn
/// after the update pass that asked for it.
///
/// The deferral is the point: a second update pass before the block drains
/// must not apply the same command again, and a block that drains after the
/// composer is gone must not apply it at all.
@MainActor
struct ComposerSlashAcceptanceTests {
    private struct Harness {
        let window: NSWindow
        let host: ScrollableComposerTextView
        let coordinator: MarkdownComposerTextView.Coordinator
        let pending: Binding<SlashCommand?>

        var view: ComposerNSTextView { host.composerTextView }

        /// Lets the main queue run the deferred block. `Task.sleep` suspends
        /// the test off the main thread, which a `RunLoop` spin does not.
        func drain() async throws {
            try await Task.sleep(for: .milliseconds(50))
        }

        func close() {
            window.contentView = nil
            window.close()
        }
    }

    private final class Box {
        var command: SlashCommand?
    }

    private static func makeHarness() -> Harness {
        let host = ScrollableComposerTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.composerTextView.loadDocument(NSAttributedString(string: ""))
        window.makeFirstResponder(host.composerTextView)

        let text = Box()
        let coordinator = MarkdownComposerTextView.Coordinator(
            text: Binding(get: { "" }, set: { _ in }),
            isFocused: FocusState<Bool>().projectedValue,
            onSend: {},
            placeholder: "",
            onTextChange: { _ in }
        )
        coordinator.textView = host.composerTextView
        let pending = Binding<SlashCommand?>(get: { text.command }, set: { text.command = $0 })
        return Harness(window: window, host: host, coordinator: coordinator, pending: pending)
    }

    private static func command(_ name: String) -> SlashCommand {
        SlashCommand(name: name, description: "", argumentHint: "")
    }

    @Test func acceptingTwiceBeforeItDrainsAppliesItOnce() async throws {
        let harness = Self.makeHarness()
        defer { harness.close() }
        harness.view.insertText("/mod", replacementRange: NSRange(location: NSNotFound, length: 0))

        harness.coordinator.acceptSlashCommand(Self.command("model"), clearing: harness.pending)
        harness.coordinator.acceptSlashCommand(Self.command("model"), clearing: harness.pending)
        try await harness.drain()

        #expect(harness.view.string == "/model ")
        #expect(harness.pending.wrappedValue == nil)
    }

    /// The composer can be gone by the time the block runs — a tab switch
    /// replaces the text view, and a closed window leaves it without one.
    @Test func acceptingDoesNothingOnceTheComposerHasLeftItsWindow() async throws {
        let harness = Self.makeHarness()
        harness.view.insertText("/mod", replacementRange: NSRange(location: NSNotFound, length: 0))

        harness.coordinator.acceptSlashCommand(Self.command("model"), clearing: harness.pending)
        harness.close()
        try await harness.drain()

        #expect(harness.view.string == "/mod")
    }
}
