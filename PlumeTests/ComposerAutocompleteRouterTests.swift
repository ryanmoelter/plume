import AppKit
import Foundation
import Testing
@testable import Plume

/// Keys reach whichever of the composer's two lists has rows, and fall
/// through to the text view when neither does. Esc and Return also reach a
/// mention menu that is still searching.
@MainActor
struct ComposerAutocompleteRouterTests {
    private let sources = FakeMentionSources()

    private func makeRouter() -> ComposerAutocompleteRouter {
        ComposerAutocompleteRouter(
            mention: MentionAutocompleteController(sources: sources, sleep: { _ in }, homeDirectory: "/Users/test")
        )
    }

    private func showMentions(_ router: ComposerAutocompleteRouter) async {
        sources.linearAnswer = { _ in
            [MentionFixtures.issue("DROID-1", "One"), MentionFixtures.issue("DROID-2", "Two")]
                .map { MentionFixtures.ranked(.linear($0)) }
        }
        router.mention.update(text: "@dro", caretLocation: 4, directory: nil, isCommandMode: false)
        await router.mention.settled()
    }

    @Test func arrowsMoveTheMentionSelection() async {
        let router = makeRouter()
        let textView = ComposerNSTextView()
        textView.autocompleteHandler = router
        await showMentions(router)

        textView.keyDown(with: Self.key(125))

        #expect(router.mention.selectedIndex == 1)
    }

    @Test func escapeClosesTheMentionsBeforeTheInterrupt() async {
        let router = makeRouter()
        let textView = ComposerNSTextView()
        var escapes = 0
        textView.autocompleteHandler = router
        textView.onEscape = { _ in escapes += 1; return true }
        await showMentions(router)

        textView.keyDown(with: Self.key(53))

        #expect(!router.mention.isPresented)
        #expect(escapes == 0)
    }

    @Test func theSlashListWinsOverMentions() async {
        let router = makeRouter()
        await showMentions(router)
        router.slash.update(
            text: "/re",
            caretLocation: 3,
            commands: [SlashCommand(name: "review", description: "", argumentHint: ""), SlashCommand(name: "resume", description: "", argumentHint: "")]
        )
        #expect(router.slash.isShowing)

        router.moveSelection(by: 1)

        #expect(router.slash.selectedIndex == 1)
        #expect(router.mention.selectedIndex == 0)
    }

    @Test func escapeClosesALoadingMentionMenuWithoutInterrupting() async {
        sources.holdsFiles = true
        defer { sources.releaseAll() }
        let router = makeRouter()
        let textView = ComposerNSTextView()
        var escapes = 0
        textView.autocompleteHandler = router
        textView.onEscape = { _ in escapes += 1; return true }
        router.mention.update(text: "@zz", caretLocation: 3, directory: "/repo", isCommandMode: false)
        await sources.waitForHeldFiles(1)

        textView.keyDown(with: Self.key(53))

        #expect(escapes == 0)
        #expect(!router.mention.isPresented)
        router.mention.update(text: "@zzz", caretLocation: 4, directory: "/repo", isCommandMode: false)
        #expect(!router.mention.isPresented)
    }

    @Test func onlyALoadingMentionMenuClaimsReturn() async {
        sources.holdsFiles = true
        defer { sources.releaseAll() }
        let router = makeRouter()
        #expect(!router.claimsReturn)

        router.mention.update(text: "@zz", caretLocation: 3, directory: "/repo", isCommandMode: false)
        #expect(router.claimsReturn)

        router.slash.update(text: "/re", caretLocation: 3, commands: [SlashCommand(name: "review", description: "", argumentHint: "")])
        #expect(!router.claimsReturn)
    }

    @Test func escapeKeepsTheSlashListClosedForThatCommand() {
        let router = makeRouter()
        let commands = [SlashCommand(name: "review", description: "", argumentHint: ""), SlashCommand(name: "resume", description: "", argumentHint: "")]
        router.slash.update(text: "/r", caretLocation: 2, commands: commands)
        #expect(router.claimsEscape)

        router.dismiss()
        router.slash.update(text: "/re", caretLocation: 3, commands: commands)
        #expect(!router.slash.isShowing)

        router.slash.update(text: "", caretLocation: 0, commands: commands)
        router.slash.update(text: "/r", caretLocation: 2, commands: commands)
        #expect(router.slash.isShowing)
    }

    private static func key(_ keyCode: UInt16) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: keyCode
        )!
    }
}
