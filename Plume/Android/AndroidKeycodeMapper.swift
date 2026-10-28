import AppKit
import ScrcpyControl

nonisolated enum AndroidKeyInput: Sendable, Hashable {
    case key(phase: DeviceKeyPhase, keycode: UInt32, metaState: UInt32)
    case text(String)
}

/// Maps Mac key events to scrcpy input for a physical device. Unmodified printable keys go as text,
/// so the Mac's keyboard layout decides the character; everything else goes as an Android keycode.
nonisolated enum AndroidKeycodeMapper {
    private static let commandKeyCodes: Set<UInt16> = [54, 55]

    /// Keys that never type a character. Keyed by Mac virtual keycode.
    private static let namedKeys: [UInt16: UInt32] = [
        36: Android.KeyCode.enter, 76: Android.KeyCode.enter,
        48: Android.KeyCode.tab,
        51: Android.KeyCode.del,
        117: Android.KeyCode.forwardDel,
        53: Android.KeyCode.escape,
        123: Android.KeyCode.dpadLeft, 124: Android.KeyCode.dpadRight,
        125: Android.KeyCode.dpadDown, 126: Android.KeyCode.dpadUp,
        115: Android.KeyCode.moveHome, 119: Android.KeyCode.moveEnd,
        116: Android.KeyCode.pageUp, 121: Android.KeyCode.pageDown,
    ]

    /// ANSI positions, for chords such as Control-C that must reach the app as keycodes, not text.
    private static let characterKeys: [UInt16: UInt32] = {
        let letters: [Character: UInt16] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
            "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32,
            "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
        ]
        var map: [UInt16: UInt32] = [:]
        for (letter, macCode) in letters {
            map[macCode] = 29 + UInt32(letter.asciiValue! - Character("a").asciiValue!)
        }
        let digits: [UInt16] = [29, 18, 19, 20, 21, 23, 22, 26, 28, 25]
        for (digit, macCode) in digits.enumerated() { map[macCode] = 7 + UInt32(digit) }
        let punctuation: [UInt16: UInt32] = [
            50: 68, 27: 69, 24: 70, 33: 71, 30: 72, 42: 73, 41: 74, 39: 75, 44: 76, 43: 55, 47: 56,
            49: Android.KeyCode.space,
        ]
        map.merge(punctuation) { _, new in new }
        return map
    }()

    static func inputs(
        type: KeyEventType,
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        characters: String?
    ) -> [AndroidKeyInput]? {
        guard type != .flagsChanged else { return nil }
        if type == .keyDown, modifierFlags.contains(.command) { return nil }
        if commandKeyCodes.contains(keyCode) { return nil }
        let phase: DeviceKeyPhase = type == .keyDown ? .down : .up
        let meta = metaState(modifierFlags)

        if let keycode = namedKeys[keyCode] {
            return [.key(phase: phase, keycode: keycode, metaState: meta)]
        }
        if modifierFlags.contains(.control) {
            guard let keycode = characterKeys[keyCode] else { return nil }
            return [.key(phase: phase, keycode: keycode, metaState: meta)]
        }
        guard let characters, isPrintable(characters) else { return nil }
        // The text was injected on key down; the release has nothing left to send but is still the device's.
        return type == .keyDown ? [.text(characters)] : []
    }

    static func metaState(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var meta = Android.Meta.none
        if flags.contains(.shift) { meta |= Android.Meta.shiftOn | Android.Meta.shiftLeftOn }
        if flags.contains(.control) { meta |= Android.Meta.ctrlOn | Android.Meta.ctrlLeftOn }
        if flags.contains(.option) { meta |= Android.Meta.altOn | Android.Meta.altLeftOn }
        if flags.contains(.capsLock) { meta |= Android.Meta.capsLockOn }
        return meta
    }

    /// Function keys arrive as characters in the U+F700 private-use block.
    private static func isPrintable(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { scalar in
            scalar.value >= 0x20 && scalar.value != 0x7F && !(0xF700...0xF8FF).contains(scalar.value)
        }
    }
}
