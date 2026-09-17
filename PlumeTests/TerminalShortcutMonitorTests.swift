import AppKit
import Testing

@testable import Plume

/// Covers which chords `TerminalShortcutMonitor` claims back from a focused
/// terminal. A false positive here silently eats a keystroke the terminal
/// needed, so the near-miss cases matter as much as the matches.
@MainActor
struct TerminalShortcutMonitorTests {
    @Test func everyBoundShortcutIsClaimed() {
        for shortcut in PlumeShortcuts.all {
            let flags = MenuShortcut.appKitFlags(shortcut.modifiers)
            #expect(
                TerminalShortcutMonitor.isClaimed(characters: String(shortcut.key), flags: flags),
                "\(shortcut.modifiers) \(shortcut.key) should be claimed"
            )
        }
    }

    @Test func plainTypingIsNeverClaimed() {
        for character in "abcdefghijklmnopqrstuvwxyz0123456789[]" {
            #expect(!TerminalShortcutMonitor.isClaimed(characters: String(character), flags: []))
        }
    }

    /// The terminal sends these as C0 control codes and Meta sequences; taking
    /// one would break ⌃C or Option-composed input.
    @Test func controlAndOptionChordsAreLeftToTheTerminal() {
        #expect(!TerminalShortcutMonitor.isClaimed(characters: "t", flags: [.control]))
        #expect(!TerminalShortcutMonitor.isClaimed(characters: "t", flags: [.option]))
        #expect(!TerminalShortcutMonitor.isClaimed(characters: "a", flags: [.control]))
        #expect(!TerminalShortcutMonitor.isClaimed(characters: "c", flags: [.control]))
        #expect(!TerminalShortcutMonitor.isClaimed(characters: "n", flags: [.option]))
    }

    @Test func commandChordsPlumeDoesNotBindPassThrough() {
        for character in "bcdefghijklmopqrsuvxyz" {
            #expect(
                !TerminalShortcutMonitor.isClaimed(characters: String(character), flags: [.command]),
                "⌘\(character) is unbound and should pass through"
            )
        }
        #expect(!TerminalShortcutMonitor.isClaimed(characters: "0", flags: [.command]))
    }

    /// The modifier set is compared whole, so a chord never matches a
    /// differently-modified version of the same key.
    @Test func extraOrMissingModifiersDoNotMatch() {
        #expect(TerminalShortcutMonitor.isClaimed(characters: "]", flags: [.command]))
        #expect(TerminalShortcutMonitor.isClaimed(characters: "]", flags: [.command, .shift]))
        #expect(!TerminalShortcutMonitor.isClaimed(characters: "]", flags: [.command, .control]))
        #expect(!TerminalShortcutMonitor.isClaimed(characters: "]", flags: [.command, .option]))

        // ⌘T and ⌘⌥T are both bound; ⌘⇧T and ⌘⌃T are not.
        #expect(TerminalShortcutMonitor.isClaimed(characters: "t", flags: [.command]))
        #expect(TerminalShortcutMonitor.isClaimed(characters: "t", flags: [.command, .option]))
        #expect(!TerminalShortcutMonitor.isClaimed(characters: "t", flags: [.command, .shift]))
        #expect(!TerminalShortcutMonitor.isClaimed(characters: "t", flags: [.command, .control]))

        // ⌘⇧A and ⌘⌃A are bound; plain ⌘A (select all) is not.
        #expect(!TerminalShortcutMonitor.isClaimed(characters: "a", flags: [.command]))
        #expect(TerminalShortcutMonitor.isClaimed(characters: "a", flags: [.command, .shift]))
        #expect(TerminalShortcutMonitor.isClaimed(characters: "a", flags: [.command, .control]))
    }

    /// Caps lock and the numeric-pad bit ride along on real events; they must
    /// not stop an otherwise-exact chord from matching.
    @Test func incidentalModifierBitsAreIgnored() {
        #expect(TerminalShortcutMonitor.isClaimed(characters: "n", flags: [.command, .capsLock]))
        #expect(TerminalShortcutMonitor.isClaimed(characters: "1", flags: [.command, .numericPad]))
        #expect(TerminalShortcutMonitor.isClaimed(characters: "w", flags: [.command, .function]))
    }

    @Test func aKeyWithNoCharactersIsNeverClaimed() {
        #expect(!TerminalShortcutMonitor.isClaimed(characters: nil, flags: [.command]))
    }

    /// Caps lock makes AppKit report "N" where the shortcut declares "n".
    @Test func matchingIsCaseInsensitive() {
        #expect(TerminalShortcutMonitor.isClaimed(characters: "N", flags: [.command]))
        #expect(TerminalShortcutMonitor.isClaimed(characters: "A", flags: [.command, .shift]))
    }

    @Test func everyClaimedShortcutCarriesCommand() {
        #expect(PlumeShortcuts.all.allSatisfy { $0.isClaimable })
    }

    @Test func tabSelectionCoversOneThroughNine() {
        #expect(PlumeShortcuts.selectTab.map(\.key) == Array("123456789"))
    }
}
