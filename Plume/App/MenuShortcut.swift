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
struct MenuShortcut: Equatable, Codable {
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
    /// A Command chord always qualifies: Command is the one modifier that
    /// never reaches a program over a PTY, so taking it costs the terminal
    /// nothing. An Option chord qualifies only because the user asked for it
    /// by binding one — the terminal otherwise uses Option to compose
    /// characters and to send Meta-prefixed escape sequences, so claiming it
    /// takes a key the shell would have received. Bare keys and Control
    /// chords stay with the terminal unconditionally: a bare key is typing
    /// and a Control chord is a C0 control code (⌃C, ⌃D, ⌃Z).
    var isClaimable: Bool { modifiers.contains(.command) || modifiers.contains(.option) }

    /// The chord as macOS writes it, for menus and the settings editor.
    var displayName: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + String(key).uppercased()
    }

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

/// Persistence. `Character` and `EventModifiers` are neither of them
/// `Codable`, so the stored form is a string key plus the modifier names —
/// readable in `defaults read`, and stable if `EventModifiers`' bit values
/// ever move.
extension MenuShortcut {
    private enum CodingKeys: String, CodingKey {
        case key
        case modifiers
    }

    private static let modifierNames: [(name: String, modifier: EventModifiers)] = [
        ("command", .command), ("shift", .shift), ("option", .option), ("control", .control),
    ]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let keyText = try container.decode(String.self, forKey: .key)
        guard keyText.count == 1, let key = keyText.first else {
            throw DecodingError.dataCorruptedError(
                forKey: .key,
                in: container,
                debugDescription: "Expected a single character, got \"\(keyText)\""
            )
        }
        let names = Set(try container.decode([String].self, forKey: .modifiers))
        let modifiers = Self.modifierNames
            .filter { names.contains($0.name) }
            .reduce(into: EventModifiers()) { $0.insert($1.modifier) }
        self.init(key, modifiers: modifiers)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(String(key), forKey: .key)
        try container.encode(
            Self.modifierNames.filter { modifiers.contains($0.modifier) }.map(\.name),
            forKey: .modifiers
        )
    }
}

extension View {
    func keyboardShortcut(_ shortcut: MenuShortcut) -> some View {
        keyboardShortcut(shortcut.keyEquivalent, modifiers: shortcut.modifiers)
    }

    /// Nil leaves the item with no chord, which is how a rebind that took this
    /// action's chord away renders.
    @ViewBuilder
    func keyboardShortcut(_ shortcut: MenuShortcut?) -> some View {
        if let shortcut {
            keyboardShortcut(shortcut.keyEquivalent, modifiers: shortcut.modifiers)
        } else {
            self
        }
    }
}
