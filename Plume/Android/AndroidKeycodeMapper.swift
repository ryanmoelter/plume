import AppKit
import ScrcpyControl

nonisolated enum AndroidKeyInput: Sendable, Hashable {
    /// `repeatCount` is how many auto-repeats of the key-down came before this one.
    case key(phase: DeviceKeyPhase, keycode: UInt32, metaState: UInt32, repeatCount: UInt32 = 0)
    case text(String)
}

/// One side of a modifier, as the Mac reports it and as Android names it.
nonisolated enum AndroidModifierKey: CaseIterable, Sendable, Hashable {
    case shiftLeft, shiftRight, ctrlLeft, ctrlRight, altLeft, altRight, metaLeft, metaRight

    init?(macKeyCode: UInt16) {
        guard let key = Self.allCases.first(where: { $0.macKeyCode == macKeyCode }) else { return nil }
        self = key
    }

    var macKeyCode: UInt16 {
        switch self {
        case .shiftLeft: 56
        case .shiftRight: 60
        case .ctrlLeft: 59
        case .ctrlRight: 62
        case .altLeft: 58
        case .altRight: 61
        case .metaLeft: 55
        case .metaRight: 54
        }
    }

    var keycode: UInt32 {
        switch self {
        case .shiftLeft: 59
        case .shiftRight: 60
        case .ctrlLeft: 113
        case .ctrlRight: 114
        case .altLeft: 57
        case .altRight: 58
        case .metaLeft: 117
        case .metaRight: 118
        }
    }

    var isMeta: Bool { self == .metaLeft || self == .metaRight }

    /// The `NX_DEVICE…KEYMASK` bit AppKit sets in `modifierFlags` while this side is down.
    var deviceMask: UInt {
        switch self {
        case .shiftLeft: 0x02
        case .shiftRight: 0x04
        case .ctrlLeft: 0x01
        case .ctrlRight: 0x2000
        case .altLeft: 0x20
        case .altRight: 0x40
        case .metaLeft: 0x08
        case .metaRight: 0x10
        }
    }

    var flag: NSEvent.ModifierFlags {
        switch self {
        case .shiftLeft, .shiftRight: .shift
        case .ctrlLeft, .ctrlRight: .control
        case .altLeft, .altRight: .option
        case .metaLeft, .metaRight: .command
        }
    }

    var metaBits: UInt32 {
        switch self {
        case .shiftLeft: Android.Meta.shiftOn | Android.Meta.shiftLeftOn
        case .shiftRight: Android.Meta.shiftOn | Android.Meta.shiftRightOn
        case .ctrlLeft: Android.Meta.ctrlOn | Android.Meta.ctrlLeftOn
        case .ctrlRight: Android.Meta.ctrlOn | Android.Meta.ctrlRightOn
        case .altLeft: Android.Meta.altOn | Android.Meta.altLeftOn
        case .altRight: Android.Meta.altOn | Android.Meta.altRightOn
        case .metaLeft: Android.Meta.metaOn | Android.Meta.metaLeftOn
        case .metaRight: Android.Meta.metaOn | Android.Meta.metaRightOn
        }
    }

    /// The sides held in `flags`. A flag set with neither side's device bit, as a synthetic event
    /// has, counts as the left side.
    static func held(in flags: NSEvent.ModifierFlags) -> [AndroidModifierKey] {
        allCases.filter { key in
            guard flags.contains(key.flag) else { return false }
            let sides = allCases.filter { $0.flag == key.flag }
            guard sides.contains(where: { flags.rawValue & $0.deviceMask != 0 }) else {
                return key == sides.first
            }
            return flags.rawValue & key.deviceMask != 0
        }
    }

    static func metaState(of keys: some Sequence<AndroidModifierKey>) -> UInt32 {
        keys.reduce(Android.Meta.none) { $0 | $1.metaBits }
    }
}

/// Maps Mac key events to scrcpy input for a physical device, following the scrcpy client's default
/// SDK keyboard with "mixed" key injection (`app/src/keyboard_sdk.c`): named keys, modifiers, letters
/// and space go as Android keycodes, and the key's text goes as a text event unless it starts with a
/// letter or space, so the Mac's keyboard layout decides every other character.
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

    /// Key-down and key-up only; `AndroidPressedKeys` handles modifier changes. Nil when nothing goes
    /// to the device, so the caller passes the event on.
    static func inputs(
        type: KeyEventType,
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        characters: String?,
        charactersIgnoringModifiers: String?
    ) -> [AndroidKeyInput]? {
        guard type != .flagsChanged else { return nil }
        let phase: DeviceKeyPhase = type == .keyDown ? .down : .up
        // The letter comes from the layout rather than the key's position, so an AZERTY "a" sends
        // KEYCODE_A.
        let keycode = namedKeys[keyCode] ?? letterOrSpaceKeycode(charactersIgnoringModifiers)
        let key = keycode.map { AndroidKeyInput.key(phase: phase, keycode: $0, metaState: metaState(modifierFlags)) }
        // SDL sends no text for a ⌘ chord, and scrcpy drops text starting with a letter or space
        // because the key event already sent it. Option-A therefore sends KEYCODE_A with Alt and "å".
        // A dead key types nothing; its character arrives with the next key's.
        let text = characters.flatMap { characters -> AndroidKeyInput? in
            guard type == .keyDown, !modifierFlags.contains(.command), isPrintable(characters),
                  !isLetterOrSpace(characters.unicodeScalars.first!)
            else { return nil }
            return .text(characters)
        }
        if key == nil, text == nil {
            // The text went on key down; the release has nothing left to send but is still the device's.
            return type == .keyUp && characters.map(isPrintable) == true && !modifierFlags.contains(.command) ? [] : nil
        }
        return [key, text].compactMap { $0 }
    }

    static func metaState(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var meta = AndroidModifierKey.metaState(of: AndroidModifierKey.held(in: flags))
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

    /// C's `isalpha` in the C locale, plus space, which is what scrcpy tests a text event against.
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

/// What the device holds down, so every press it was sent gets its release.
///
/// Each key-up routes by what its key-down sent, not by the modifiers held at release: a Control-C
/// whose Control is let go first must still release KEYCODE_C. A key-up whose key-down never reached
/// the device sends nothing. Modifiers go down and up as the Mac reports them, and a key-down first
/// brings the device's modifiers in line with the event's flags, which covers a modifier pressed
/// before this view had focus or after `releaseAll()`.
nonisolated struct AndroidPressedKeys {
    private struct PressedKey {
        var keycode: UInt32
        var repeatCount: UInt32
    }

    /// Keyed by Mac virtual keycode: what its key-down sent.
    private var pressed: [UInt16: PressedKey] = [:]
    private var modifiers: [AndroidModifierKey] = []

    var isEmpty: Bool { pressed.isEmpty && modifiers.isEmpty }

    /// Nil when the event isn't the device's, so the caller passes it on.
    mutating func inputs(
        type: KeyEventType,
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        characters: String?,
        charactersIgnoringModifiers: String?,
        isRepeat: Bool = false
    ) -> [AndroidKeyInput]? {
        let metaState = AndroidKeycodeMapper.metaState(modifierFlags)
        if type == .flagsChanged {
            guard let key = AndroidModifierKey(macKeyCode: keyCode) else { return nil }
            let isDown = AndroidModifierKey.held(in: modifierFlags).contains(key)
            guard isDown != modifiers.contains(key) else { return [] }
            if isDown { modifiers.append(key) } else { modifiers.removeAll { $0 == key } }
            return [.key(phase: isDown ? .down : .up, keycode: key.keycode, metaState: metaState)]
        }
        if type == .keyUp, let key = pressed.removeValue(forKey: keyCode) {
            return [.key(phase: .up, keycode: key.keycode, metaState: metaState)]
        }
        guard let inputs = AndroidKeycodeMapper.inputs(
            type: type, keyCode: keyCode, modifierFlags: modifierFlags,
            characters: characters, charactersIgnoringModifiers: charactersIgnoringModifiers
        ) else { return nil }
        guard type == .keyDown else { return [] }
        let repeatCount = isRepeat ? (pressed[keyCode]?.repeatCount ?? 0) + 1 : 0
        return syncModifiers(to: modifierFlags) + inputs.map { input in
            guard case .key(.down, let keycode, let metaState, _) = input else { return input }
            pressed[keyCode] = PressedKey(keycode: keycode, repeatCount: repeatCount)
            return .key(phase: .down, keycode: keycode, metaState: metaState, repeatCount: repeatCount)
        }
    }

    /// Releases everything the device holds: keys, then modifiers, Meta last.
    ///
    /// Android's window manager opens All Apps on a Meta release when no other key came between it and
    /// its press (`mPendingMetaAction` in `KeyGestureController`). So when Meta is all that's held, a
    /// Control press and release goes first: Control does nothing on its own, and any non-Meta key
    /// cancels that action. The release can't be marked canceled instead, since scrcpy's inject
    /// message carries no flags.
    mutating func releaseAll() -> [AndroidKeyInput] {
        var inputs: [AndroidKeyInput] = []
        for keyCode in pressed.keys.sorted() {
            let key = pressed.removeValue(forKey: keyCode)!
            inputs.append(.key(phase: .up, keycode: key.keycode, metaState: AndroidModifierKey.metaState(of: modifiers)))
        }
        for key in modifiers where !key.isMeta {
            inputs.append(release(key))
        }
        if inputs.isEmpty, modifiers.contains(where: \.isMeta) {
            let cancel = AndroidModifierKey.ctrlLeft
            let metaState = AndroidModifierKey.metaState(of: modifiers)
            inputs.append(.key(phase: .down, keycode: cancel.keycode, metaState: metaState | cancel.metaBits))
            inputs.append(.key(phase: .up, keycode: cancel.keycode, metaState: metaState))
        }
        for key in modifiers {
            inputs.append(release(key))
        }
        return inputs
    }

    private mutating func syncModifiers(to flags: NSEvent.ModifierFlags) -> [AndroidKeyInput] {
        let held = AndroidModifierKey.held(in: flags)
        var inputs = modifiers.filter { !held.contains($0) }.map { release($0) }
        for key in held where !modifiers.contains(key) {
            modifiers.append(key)
            inputs.append(.key(phase: .down, keycode: key.keycode, metaState: AndroidModifierKey.metaState(of: modifiers)))
        }
        return inputs
    }

    private mutating func release(_ key: AndroidModifierKey) -> AndroidKeyInput {
        modifiers.removeAll { $0 == key }
        return .key(phase: .up, keycode: key.keycode, metaState: AndroidModifierKey.metaState(of: modifiers))
    }
}

/// Whether a chord stays with Plume's menus instead of going to a physical device.
nonisolated enum AndroidShortcutPolicy {
    /// `keepsPlumeShortcuts` off hands the device every ⌘ chord, Plume's own included; a Plume
    /// shortcut without ⌘ stays on the Mac either way.
    static func keepsOnMac(
        characters: String?,
        flags: NSEvent.ModifierFlags,
        keepsPlumeShortcuts: Bool,
        isPlumeShortcut: (String?, NSEvent.ModifierFlags) -> Bool
    ) -> Bool {
        guard isPlumeShortcut(characters, flags) else { return false }
        return keepsPlumeShortcuts || !flags.contains(.command)
    }
}
