import AppKit

enum DevicePasteShortcut {
    enum Action: Equatable {
        case paste
        /// A held ⌘V's auto-repeat: no paste, but Meta still comes up.
        case releaseKeysOnly
    }

    private static let shortcut = MenuShortcut("v")

    /// ⌘V alone. ⌘⇧V and other chords with V still reach a physical device as Meta plus the key.
    static func matches(characters: String?, flags: NSEvent.ModifierFlags) -> Bool {
        shortcut.matches(characters: characters, flags: flags)
    }

    /// Nil for any chord but ⌘V.
    static func action(characters: String?, flags: NSEvent.ModifierFlags, isRepeat: Bool) -> Action? {
        guard matches(characters: characters, flags: flags) else { return nil }
        return isRepeat ? .releaseKeysOnly : .paste
    }

    /// Nil when there is nothing to send.
    static func text(from pasteboard: NSPasteboard) -> String? {
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return nil }
        return text
    }
}
