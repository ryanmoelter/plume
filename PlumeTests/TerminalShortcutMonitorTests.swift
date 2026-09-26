import AppKit
import Testing

@testable import Plume

/// Covers which chords `TerminalShortcutMonitor` claims back from a focused
/// terminal. A false positive here silently eats a keystroke the terminal
/// needed, so the near-miss cases matter as much as the matches.
@MainActor
struct TerminalShortcutMonitorTests {
    /// The shipped chords, not the live ones. `PlumeShortcuts.all` reads
    /// `AppSettings.shared`, whose rebindable half is whatever the developer
    /// running these tests last chose in Settings.
    private let defaults = PlumeShortcuts.all(with: ShortcutBindings())

    @Test func everyBoundShortcutIsClaimed() {
        for shortcut in defaults {
            let flags = MenuShortcut.appKitFlags(shortcut.modifiers)
            #expect(
                TerminalShortcutMonitor.isClaimed(shortcuts: defaults, characters: String(shortcut.key), flags: flags),
                "\(shortcut.modifiers) \(shortcut.key) should be claimed"
            )
        }
    }

    @Test func plainTypingIsNeverClaimed() {
        for character in "abcdefghijklmnopqrstuvwxyz0123456789[]" {
            #expect(!TerminalShortcutMonitor.isClaimed(shortcuts: defaults, characters: String(character), flags: []))
        }
    }

    /// The terminal sends these as C0 control codes and Meta sequences; taking
    /// one would break ⌃C or Option-composed input.
    @Test func controlAndOptionChordsAreLeftToTheTerminal() {
        #expect(!TerminalShortcutMonitor.isClaimed(shortcuts: defaults, characters: "t", flags: [.control]))
        #expect(!TerminalShortcutMonitor.isClaimed(shortcuts: defaults, characters: "t", flags: [.option]))
        #expect(!TerminalShortcutMonitor.isClaimed(shortcuts: defaults, characters: "a", flags: [.control]))
        #expect(!TerminalShortcutMonitor.isClaimed(shortcuts: defaults, characters: "c", flags: [.control]))
        #expect(!TerminalShortcutMonitor.isClaimed(shortcuts: defaults, characters: "n", flags: [.option]))
    }

    /// ⌘H and ⌘Q are absent here on purpose — AppKit's own Hide and Quit
    /// items claim those, covered by `systemMenuShortcutsAreClaimedEvenWithAnEmptyShortcutList` below.
    @Test func commandChordsPlumeDoesNotBindPassThrough() {
        for character in "bcdefgijklmoprsuvxyz" {
            #expect(
                !TerminalShortcutMonitor.isClaimed(shortcuts: defaults, characters: String(character), flags: [.command]),
                "⌘\(character) is unbound and should pass through"
            )
        }
        #expect(!TerminalShortcutMonitor.isClaimed(shortcuts: defaults, characters: "0", flags: [.command]))
    }

    /// Settings, Hide and Quit come from AppKit's own app menu, not a button
    /// in `PlumeCommands`, so no `shortcuts` list carries them — `isClaimed`
    /// adds them itself.
    @Test func systemMenuShortcutsAreClaimedEvenWithAnEmptyShortcutList() {
        #expect(TerminalShortcutMonitor.isClaimed(shortcuts: [], characters: ",", flags: [.command]))
        #expect(TerminalShortcutMonitor.isClaimed(shortcuts: [], characters: "h", flags: [.command]))
        #expect(TerminalShortcutMonitor.isClaimed(shortcuts: [], characters: "q", flags: [.command]))
    }

    /// Edit-menu chords are the same kind of automatic AppKit item, but a
    /// terminal needs them for its own editing and clipboard, so they must
    /// stay unclaimed.
    @Test func editMenuChordsStayWithTheTerminal() {
        #expect(!TerminalShortcutMonitor.isClaimed(shortcuts: [], characters: "z", flags: [.command]))
        #expect(!TerminalShortcutMonitor.isClaimed(shortcuts: [], characters: "x", flags: [.command]))
        #expect(!TerminalShortcutMonitor.isClaimed(shortcuts: [], characters: "c", flags: [.command]))
        #expect(!TerminalShortcutMonitor.isClaimed(shortcuts: [], characters: "v", flags: [.command]))
        #expect(!TerminalShortcutMonitor.isClaimed(shortcuts: [], characters: "a", flags: [.command]))
    }

    /// The modifier set is compared whole, so a chord never matches a
    /// differently-modified version of the same key.
    @Test func extraOrMissingModifiersDoNotMatch() {
        #expect(TerminalShortcutMonitor.isClaimed(shortcuts: defaults, characters: "]", flags: [.command]))
        #expect(TerminalShortcutMonitor.isClaimed(shortcuts: defaults, characters: "]", flags: [.command, .shift]))
        #expect(!TerminalShortcutMonitor.isClaimed(shortcuts: defaults, characters: "]", flags: [.command, .control]))
        #expect(!TerminalShortcutMonitor.isClaimed(shortcuts: defaults, characters: "]", flags: [.command, .option]))

        // ⌘T and ⌘⌥T are both bound; ⌘⇧T and ⌘⌃T are not.
        #expect(TerminalShortcutMonitor.isClaimed(shortcuts: defaults, characters: "t", flags: [.command]))
        #expect(TerminalShortcutMonitor.isClaimed(shortcuts: defaults, characters: "t", flags: [.command, .option]))
        #expect(!TerminalShortcutMonitor.isClaimed(shortcuts: defaults, characters: "t", flags: [.command, .shift]))
        #expect(!TerminalShortcutMonitor.isClaimed(shortcuts: defaults, characters: "t", flags: [.command, .control]))

        // ⌘⇧A and ⌘⌃A are bound; plain ⌘A (select all) is not.
        #expect(!TerminalShortcutMonitor.isClaimed(shortcuts: defaults, characters: "a", flags: [.command]))
        #expect(TerminalShortcutMonitor.isClaimed(shortcuts: defaults, characters: "a", flags: [.command, .shift]))
        #expect(TerminalShortcutMonitor.isClaimed(shortcuts: defaults, characters: "a", flags: [.command, .control]))
    }

    /// Caps lock and the numeric-pad bit ride along on real events; they must
    /// not stop an otherwise-exact chord from matching.
    @Test func incidentalModifierBitsAreIgnored() {
        #expect(TerminalShortcutMonitor.isClaimed(shortcuts: defaults, characters: "n", flags: [.command, .capsLock]))
        #expect(TerminalShortcutMonitor.isClaimed(shortcuts: defaults, characters: "1", flags: [.command, .numericPad]))
        #expect(TerminalShortcutMonitor.isClaimed(shortcuts: defaults, characters: "w", flags: [.command, .function]))
    }

    @Test func aKeyWithNoCharactersIsNeverClaimed() {
        #expect(!TerminalShortcutMonitor.isClaimed(shortcuts: defaults, characters: nil, flags: [.command]))
    }

    /// Caps lock makes AppKit report "N" where the shortcut declares "n".
    @Test func matchingIsCaseInsensitive() {
        #expect(TerminalShortcutMonitor.isClaimed(shortcuts: defaults, characters: "N", flags: [.command]))
        #expect(TerminalShortcutMonitor.isClaimed(shortcuts: defaults, characters: "A", flags: [.command, .shift]))
    }

    /// Reads the live bindings on purpose: a chord the user can record must
    /// also be one the monitor can take back from a terminal.
    @Test func everyClaimedShortcutCarriesCommandOrOption() {
        #expect(PlumeShortcuts.all.allSatisfy { $0.isClaimable })
    }

    @Test func tabSelectionCoversOneThroughNine() {
        #expect(PlumeShortcuts.selectTab.map(\.key) == Array("123456789"))
    }
}
