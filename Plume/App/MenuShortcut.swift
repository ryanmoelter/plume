import AppKit
import SwiftUI

/// One menu-bar keyboard shortcut, in the form SwiftUI needs and the form
/// AppKit needs.
///
/// `PlumeCommands` builds every one of its `keyboardShortcut` modifiers from a
/// value of this type, and `TerminalShortcutMonitor` matches `NSEvent`s against
/// the same values. That shared origin is the point: a chord added to a menu
/// item is claimed back from a focused terminal automatically, with no parallel
/// list to keep in step.
struct MenuShortcut: Equatable {
    /// The character the key produces with no modifiers applied — "a", "]",
    /// "1". Matching reads `charactersIgnoringModifiers`, so this is compared
    /// against what the key is labelled, not what the chord composes to.
    let key: Character
    let modifiers: EventModifiers

    init(_ key: Character, modifiers: EventModifiers = .command) {
        self.key = key
        self.modifiers = modifiers
    }

    var keyEquivalent: KeyEquivalent { KeyEquivalent(key) }

    /// Whether this chord may be claimed back from a focused terminal.
    ///
    /// Only Command-bearing chords qualify. Everything else belongs to the
    /// terminal: a bare key is typing, a Control chord is a C0 control code
    /// (⌃C, ⌃D, ⌃Z), and an Option chord is how a terminal composes characters
    /// and sends Meta-prefixed escape sequences. Command is the one modifier
    /// that never reaches a program over a PTY, so taking it costs the
    /// terminal nothing.
    var isClaimable: Bool { modifiers.contains(.command) }

    /// Whether `characters` and `flags` are this exact chord.
    ///
    /// Compares the whole modifier set rather than testing membership, so ⌘]
    /// does not swallow ⌘⇧] and vice versa. Shift participates through
    /// `charactersIgnoringModifiers`, which reports "]" for both, leaving the
    /// declared `.shift` to tell them apart.
    func matches(characters: String?, flags: NSEvent.ModifierFlags) -> Bool {
        guard isClaimable else { return false }
        guard let characters, characters.lowercased() == String(key).lowercased() else { return false }
        return MenuShortcut.deviceIndependentFlags(flags) == MenuShortcut.appKitFlags(modifiers)
    }

    /// Drops the caps-lock, function and numeric-pad bits AppKit sets on its
    /// own. Leaving them in makes an otherwise-identical chord miss whenever
    /// caps lock happens to be on.
    static func deviceIndependentFlags(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        flags.intersection([.command, .shift, .option, .control])
    }

    static func appKitFlags(_ modifiers: EventModifiers) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers.contains(.command) { flags.insert(.command) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.control) { flags.insert(.control) }
        return flags
    }
}

extension View {
    func keyboardShortcut(_ shortcut: MenuShortcut) -> some View {
        keyboardShortcut(shortcut.keyEquivalent, modifiers: shortcut.modifiers)
    }
}
