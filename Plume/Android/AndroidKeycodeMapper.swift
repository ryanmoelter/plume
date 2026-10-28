import AppKit
import ScrcpyControl

nonisolated enum AndroidKeyInput: Sendable, Hashable {
    /// `repeatCount` is how many auto-repeats of the key-down came before this one.
    case key(phase: DeviceKeyPhase, keycode: UInt32, metaState: UInt32, repeatCount: UInt32 = 0)
    case text(String)
}

/// Maps Mac key events to scrcpy input for a physical device, following the scrcpy client's default
/// "mixed" key injection: named keys, letters and space go as Android keycodes, and every other
/// printable character goes as text, so the Mac's keyboard layout decides it.
nonisolated enum AndroidKeycodeMapper {
    /// Keys that never type a character. Keyed by Mac virtual keycode.
    private static let namedKeys: [UInt16: UInt32] = [
        36: Android.KeyCode.enter, 76: numpadEnter,
        48: Android.KeyCode.tab,
        51: Android.KeyCode.del,
        117: Android.KeyCode.forwardDel,
        53: Android.KeyCode.escape,
        123: Android.KeyCode.dpadLeft, 124: Android.KeyCode.dpadRight,
        125: Android.KeyCode.dpadDown, 126: Android.KeyCode.dpadUp,
        115: Android.KeyCode.moveHome, 119: Android.KeyCode.moveEnd,
        116: Android.KeyCode.pageUp, 121: Android.KeyCode.pageDown,
    ]
    private static let numpadEnter: UInt32 = 160
    private static let keycodeA: UInt32 = 29

    /// Nil when nothing goes to the device, so the caller passes the event on.
    static func inputs(
        type: KeyEventType,
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        characters: String?,
        charactersIgnoringModifiers: String?
    ) -> [AndroidKeyInput]? {
        guard type != .flagsChanged else { return nil }
        if type == .keyDown, modifierFlags.contains(.command) { return nil }
        let phase: DeviceKeyPhase = type == .keyDown ? .down : .up
        let meta = metaState(modifierFlags)

        if let keycode = namedKeys[keyCode] {
            return [.key(phase: phase, keycode: keycode, metaState: meta)]
        }
        // Empty for a dead key, which composes into the next key's characters.
        guard let characters, !characters.isEmpty else { return nil }
        let typesText = isPrintable(characters)
        // The letter comes from the layout rather than the key's position, so an AZERTY "a" sends
        // KEYCODE_A. A key that types anything else, such as Option-A's "å", goes as text alone.
        if let keycode = letterOrSpaceKeycode(charactersIgnoringModifiers),
           !typesText || isLetterOrSpace(characters.unicodeScalars.first!) {
            return [.key(phase: phase, keycode: keycode, metaState: meta)]
        }
        guard typesText else { return nil }
        // The text was injected on key down; the release has nothing left to send but is still the device's.
        return type == .keyDown ? [.text(characters)] : []
    }

    static func metaState(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var meta = Android.Meta.none
        if flags.contains(.shift) { meta |= Android.Meta.shiftOn | Android.Meta.shiftLeftOn }
        if flags.contains(.control) { meta |= Android.Meta.ctrlOn | Android.Meta.ctrlLeftOn }
        if flags.contains(.option) { meta |= Android.Meta.altOn | Android.Meta.altLeftOn }
        if flags.contains(.command) { meta |= Android.Meta.metaOn | Android.Meta.metaLeftOn }
        if flags.contains(.capsLock) { meta |= Android.Meta.capsLockOn }
        return meta
    }

    private static func letterOrSpaceKeycode(_ characters: String?) -> UInt32? {
        guard let characters, characters.unicodeScalars.count == 1,
              let scalar = characters.lowercased().unicodeScalars.first, isLetterOrSpace(scalar)
        else { return nil }
        if scalar == " " { return Android.KeyCode.space }
        return keycodeA + scalar.value - Character("a").unicodeScalars.first!.value
    }

    private static func isLetterOrSpace(_ scalar: Unicode.Scalar) -> Bool {
        scalar == " " || ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
    }

    /// Function keys arrive as characters in the U+F700 private-use block.
    private static func isPrintable(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { scalar in
            scalar.value >= 0x20 && scalar.value != 0x7F && !(0xF700...0xF8FF).contains(scalar.value)
        }
    }
}

/// Routes each key-up by what its key-down sent, not by the modifiers held at release: a Control-C
/// whose Control is let go first must still release KEYCODE_C. A key-up whose key-down never reached
/// the device as a keycode, such as one pressed with ⌘ held, sends nothing.
nonisolated struct AndroidPressedKeys {
    private struct PressedKey {
        var keycode: UInt32
        var repeatCount: UInt32
    }

    /// Keyed by Mac virtual keycode: what its key-down sent.
    private var pressed: [UInt16: PressedKey] = [:]

    /// Nil when the event isn't the device's, so the caller passes it on.
    mutating func inputs(
        type: KeyEventType,
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        characters: String?,
        charactersIgnoringModifiers: String?,
        isRepeat: Bool = false
    ) -> [AndroidKeyInput]? {
        if type == .keyUp, let key = pressed.removeValue(forKey: keyCode) {
            return [.key(phase: .up, keycode: key.keycode, metaState: AndroidKeycodeMapper.metaState(modifierFlags))]
        }
        guard let inputs = AndroidKeycodeMapper.inputs(
            type: type, keyCode: keyCode, modifierFlags: modifierFlags,
            characters: characters, charactersIgnoringModifiers: charactersIgnoringModifiers
        ) else { return nil }
        guard type == .keyDown else { return [] }
        let repeatCount = isRepeat ? (pressed[keyCode]?.repeatCount ?? 0) + 1 : 0
        return inputs.map { input in
            guard case .key(.down, let keycode, let metaState, _) = input else { return input }
            pressed[keyCode] = PressedKey(keycode: keycode, repeatCount: repeatCount)
            return .key(phase: .down, keycode: keycode, metaState: metaState, repeatCount: repeatCount)
        }
    }
}
