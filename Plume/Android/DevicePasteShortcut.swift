import AppKit

enum DevicePasteShortcut {
    private static let shortcut = MenuShortcut("v")

    /// ⌘V alone. ⌘⇧V and other chords with V still reach a physical device as Meta plus the key.
    static func matches(characters: String?, flags: NSEvent.ModifierFlags) -> Bool {
        shortcut.matches(characters: characters, flags: flags)
    }

    /// Nil when there is nothing to send.
    static func text(from pasteboard: NSPasteboard) -> String? {
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return nil }
        return text
    }
}
