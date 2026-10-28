import AppKit

nonisolated enum DeviceKeyPhase: Sendable, Hashable {
    case down
    case up
}

nonisolated enum DeviceKey: Sendable, Hashable {
    case mac(keyCode: Int32, phase: DeviceKeyPhase)
    case evdev(keyCode: Int32, phase: DeviceKeyPhase)
}

nonisolated enum KeyEventType: Sendable, Equatable {
    case keyDown
    case keyUp
    case flagsChanged
}

nonisolated enum EmulatorKeyMapper {
    private static let evdevKeyA: Int32 = 30
    private static let commandKeyCodes: Set<UInt16> = [54, 55]
    private static let capsLockKeyCode: UInt16 = 57

    private static let modifierFlagByKeyCode: [UInt16: NSEvent.ModifierFlags] = [
        56: .shift, 60: .shift,
        59: .control, 62: .control,
        58: .option, 61: .option,
        57: .capsLock,
    ]

    static func keyEvents(
        type: KeyEventType,
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        previousFlags: NSEvent.ModifierFlags
    ) -> [DeviceKey] {
        switch type {
        case .keyDown, .keyUp:
            // Releases always go through, or a key pressed before ⌘ would never be released in the guest.
            if type == .keyDown, modifierFlags.contains(.command) { return [] }
            if commandKeyCodes.contains(keyCode) { return [] }
            let phase: DeviceKeyPhase = type == .keyDown ? .down : .up
            // The emulator drops Mac keycode 0 (ANSI A) as a proto3 default value.
            if keyCode == 0 { return [.evdev(keyCode: evdevKeyA, phase: phase)] }
            return [.mac(keyCode: Int32(keyCode), phase: phase)]
        case .flagsChanged:
            guard let flag = modifierFlagByKeyCode[keyCode] else { return [] }
            let code = Int32(keyCode)
            if keyCode == capsLockKeyCode {
                return [.mac(keyCode: code, phase: .down), .mac(keyCode: code, phase: .up)]
            }
            let isSet = modifierFlags.contains(flag)
            let wasSet = previousFlags.contains(flag)
            if isSet && !wasSet { return [.mac(keyCode: code, phase: .down)] }
            if !isSet && wasSet { return [.mac(keyCode: code, phase: .up)] }
            return []
        }
    }
}
