#if DEBUG
import AppKit
import Carbon.HIToolbox

/// Posts a key press into a window from inside the process, without activating
/// the app.
///
/// This is the only way to test a keyboard shortcut for real. A menu item's
/// chord is dispatched by AppKit through local `.keyDown` monitors and then
/// `performKeyEquivalent`, so nothing short of a genuine `NSEvent` travelling
/// that path proves a shortcut fires.
@MainActor
enum SyntheticKey {
    /// The key code that types `character` on the active keyboard layout, or
    /// nil when no key does.
    ///
    /// Found by translating every key code rather than from a fixed table, so
    /// a non-US layout resolves to whatever key is labelled that character.
    static func keyCode(for character: Character) -> CGKeyCode? {
        if let named = named.first(where: { $0.character == character }) { return named.code }
        guard let layout = currentLayoutData() else { return nil }
        let wanted = String(character).lowercased()
        for code in CGKeyCode(0)...CGKeyCode(127) where translate(code, layout: layout)?.lowercased() == wanted {
            return code
        }
        return nil
    }

    /// The key code that types `character` with Shift held, for a character
    /// like `@` that no key types on its own.
    static func shiftedKeyCode(for character: Character) -> CGKeyCode? {
        guard let layout = currentLayoutData() else { return nil }
        let wanted = String(character)
        return (CGKeyCode(0)...CGKeyCode(127)).first { translate($0, layout: layout, flags: .shift) == wanted }
    }

    struct NamedKey {
        let name: String
        let character: Character
        let code: CGKeyCode
        /// The flags AppKit sets on its own for this key: `.function` on the
        /// navigation keys, and `.numericPad` too on the arrows.
        let flags: NSEvent.ModifierFlags
    }

    /// Keys addressed by name over the control socket, mostly ones that type
    /// no character on a layout. The characters are what AppKit reports for
    /// them, which its key bindings match on (Page Up becomes `scrollPageUp:`
    /// and ⌥← `moveWordLeft:` in a text view).
    static let named: [NamedKey] = [
        NamedKey(name: "pageup", character: "\u{F72C}", code: 116, flags: .function),
        NamedKey(name: "pagedown", character: "\u{F72D}", code: 121, flags: .function),
        NamedKey(name: "home", character: "\u{F729}", code: 115, flags: .function),
        NamedKey(name: "end", character: "\u{F72B}", code: 119, flags: .function),
        NamedKey(name: "left", character: "\u{F702}", code: 123, flags: [.function, .numericPad]),
        NamedKey(name: "right", character: "\u{F703}", code: 124, flags: [.function, .numericPad]),
        NamedKey(name: "up", character: "\u{F700}", code: 126, flags: [.function, .numericPad]),
        NamedKey(name: "down", character: "\u{F701}", code: 125, flags: [.function, .numericPad]),
        NamedKey(name: "delete", character: MenuShortcut.backspace, code: 51, flags: []),
        NamedKey(name: "forwarddelete", character: "\u{F728}", code: 117, flags: .function),
        NamedKey(name: "return", character: "\r", code: 36, flags: []),
        NamedKey(name: "tab", character: "\t", code: 48, flags: []),
        NamedKey(name: "escape", character: "\u{1B}", code: 53, flags: []),
        NamedKey(name: "space", character: " ", code: 49, flags: []),
    ]

    static func character(named name: String) -> Character? {
        named.first { $0.name == name.lowercased() }?.character
    }

    /// Delivers `shortcut` as a down/up pair to `window`, and returns the key
    /// code it pressed.
    ///
    /// The window is made key (not activated) first: a shortcut is dispatched
    /// relative to the key window, and a hidden scratch instance may have
    /// none.
    @discardableResult
    static func perform(_ shortcut: MenuShortcut, in window: NSWindow) async throws -> CGKeyCode {
        let unshifted = keyCode(for: shortcut.key)
        guard let code = unshifted ?? shiftedKeyCode(for: shortcut.key) else {
            throw ControlError.badParams("no key on this layout types \"\(shortcut.key)\"")
        }
        let namedKey = named.first { $0.character == shortcut.key }
        let flags = MenuShortcut.appKitFlags(shortcut.modifiers)
            .union(namedKey?.flags ?? [])
            .union(unshifted == nil ? .shift : [])
        // `charactersIgnoringModifiers` is what both the menu and
        // `TerminalShortcutMonitor` match on, so it carries the unmodified
        // character while `characters` carries what the chord composes to.
        let bare = String(shortcut.key)
        let characters: String
        if shortcut.key == "\t", flags.contains(.shift) {
            characters = "\u{19}"
        } else if namedKey != nil {
            characters = bare
        } else {
            characters = composed(code, flags: flags) ?? bare
        }
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: characters,
                charactersIgnoringModifiers: bare, isARepeat: false, keyCode: UInt16(code)
            )
        }
        guard let down = event(.keyDown), let up = event(.keyUp) else {
            throw ControlError.unsupported("could not build a key event")
        }
        window.makeKey()
        NSApp.postEvent(down, atStart: false)
        NSApp.postEvent(up, atStart: false)
        // Two yields: the first lets AppKit pump the posted events, the second
        // lets whatever they triggered settle before the caller reads state.
        await Task.yield()
        await Task.yield()
        return code
    }

    private static func composed(_ code: CGKeyCode, flags: NSEvent.ModifierFlags) -> String? {
        guard let layout = currentLayoutData() else { return nil }
        return translate(code, layout: layout, flags: flags)
    }

    private static func currentLayoutData() -> Data? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        return Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
    }

    private static func translate(_ code: CGKeyCode, layout: Data, flags: NSEvent.ModifierFlags = []) -> String? {
        var carbonModifiers: UInt32 = 0
        if flags.contains(.shift) { carbonModifiers |= UInt32(shiftKey >> 8) }
        if flags.contains(.option) { carbonModifiers |= UInt32(optionKey >> 8) }
        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = layout.withUnsafeBytes { buffer -> OSStatus in
            guard let base = buffer.baseAddress else { return -1 }
            return UCKeyTranslate(
                base.assumingMemoryBound(to: UCKeyboardLayout.self),
                UInt16(code), UInt16(kUCKeyActionDown), carbonModifiers,
                UInt32(LMGetKbdType()), UInt32(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState, characters.count, &length, &characters
            )
        }
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: characters, count: length)
    }
}
#endif
