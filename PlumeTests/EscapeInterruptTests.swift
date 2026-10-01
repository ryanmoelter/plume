import AppKit
import Foundation
import Testing
@testable import Plume

@MainActor
struct EscapeInterruptTests {
    @Test func aBareEscapeInterruptsARunningTurn() {
        #expect(EscapeInterrupt.shouldInterrupt(isEnabled: true, isTurnRunning: true, modifiers: []))
    }

    @Test func escapeLeavesAnIdleSessionAlone() {
        #expect(!EscapeInterrupt.shouldInterrupt(isEnabled: true, isTurnRunning: false, modifiers: []))
    }

    @Test func turningTheSettingOffLeavesEscapeAlone() {
        #expect(!EscapeInterrupt.shouldInterrupt(isEnabled: false, isTurnRunning: true, modifiers: []))
    }

    @Test(arguments: [NSEvent.ModifierFlags.command, .option, .control, .shift])
    func aModifiedEscapeIsNotAnInterrupt(_ modifier: NSEvent.ModifierFlags) {
        #expect(!EscapeInterrupt.shouldInterrupt(isEnabled: true, isTurnRunning: true, modifiers: modifier))
    }

    @Test func capsLockDoesNotBlockTheInterrupt() {
        #expect(EscapeInterrupt.shouldInterrupt(isEnabled: true, isTurnRunning: true, modifiers: .capsLock))
    }

    @Test func theSlashCommandListTakesEscapeBeforeTheInterrupt() {
        let textView = ComposerNSTextView()
        let autocomplete = StubAutocomplete()
        var escapes = 0
        textView.autocompleteHandler = autocomplete
        textView.onEscape = { _ in escapes += 1; return true }

        textView.keyDown(with: escapeEvent())

        #expect(autocomplete.dismissals == 1)
        #expect(escapes == 0)
    }

    @Test func escapeReachesTheInterruptOnceTheListIsClosed() {
        let textView = ComposerNSTextView()
        let autocomplete = StubAutocomplete()
        autocomplete.isShowing = false
        var escapes = 0
        textView.autocompleteHandler = autocomplete
        textView.onEscape = { _ in escapes += 1; return true }

        textView.keyDown(with: escapeEvent())

        #expect(autocomplete.dismissals == 0)
        #expect(escapes == 1)
    }

    @Test func settingDefaultsToOnWhenUnset() {
        let defaults = UserDefaults(suiteName: "EscapeInterruptTests-\(UUID().uuidString)")!
        #expect(AppSettings(defaults: defaults).escapeInterruptsTurn)
    }

    @Test func settingPersists() {
        let defaults = UserDefaults(suiteName: "EscapeInterruptTests-\(UUID().uuidString)")!
        AppSettings(defaults: defaults).escapeInterruptsTurn = false
        #expect(!AppSettings(defaults: defaults).escapeInterruptsTurn)
    }

    private func escapeEvent() -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false,
            keyCode: 53
        )!
    }
}

private final class StubAutocomplete: ComposerAutocompleteHandler {
    var isShowing = true
    var dismissals = 0
    func moveSelection(by delta: Int) {}
    func acceptSelection() {}
    func dismiss() { dismissals += 1 }
}
