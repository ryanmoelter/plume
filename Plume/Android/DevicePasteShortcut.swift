import AppKit

nonisolated enum DevicePasteShortcut {
    /// ⌘V alone. ⌘⇧V and other chords with V still reach a physical device as Meta plus the key.
    static func matches(characters: String?, flags: NSEvent.ModifierFlags) -> Bool {
        let modifiers = flags.intersection([.command, .shift, .control, .option])
        return modifiers == .command && characters?.lowercased() == "v"
    }

    /// Nil when there is nothing to send.
    static func text(from pasteboard: NSPasteboard) -> String? {
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return nil }
        return text
    }
}
