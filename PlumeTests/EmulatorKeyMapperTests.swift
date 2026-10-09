import AppKit
import Testing
@testable import Plume

struct EmulatorKeyMapperTests {
    private func keys(
        _ type: KeyEventType, _ code: UInt16, flags: NSEvent.ModifierFlags = [], previous: NSEvent.ModifierFlags = []
    ) -> [DeviceKey] {
        EmulatorKeyMapper.keyEvents(type: type, keyCode: code, modifierFlags: flags, previousFlags: previous)
    }

    @Test func keyDownAndUpPassThrough() {
        #expect(keys(.keyDown, 11) == [.mac(keyCode: 11, phase: .down)])
        #expect(keys(.keyUp, 11) == [.mac(keyCode: 11, phase: .up)])
    }

    @Test func keyCodeZeroBecomesEvdevA() {
        #expect(keys(.keyDown, 0) == [.evdev(keyCode: 30, phase: .down)])
        #expect(keys(.keyUp, 0) == [.evdev(keyCode: 30, phase: .up)])
    }

    @Test func commandChordsAreNotForwarded() {
        #expect(keys(.keyDown, 13, flags: .command).isEmpty)
        #expect(keys(.keyDown, 0, flags: .command).isEmpty)
    }

    @Test func keyUpWithCommandHeldStillReleasesTheKey() {
        #expect(keys(.keyUp, 13, flags: [.command, .shift]) == [.mac(keyCode: 13, phase: .up)])
        #expect(keys(.keyUp, 0, flags: .command) == [.evdev(keyCode: 30, phase: .up)])
    }

    @Test func commandKeyCodesAreNeverForwardedOnKeyUp() {
        #expect(keys(.keyUp, 54, flags: .command).isEmpty)
        #expect(keys(.keyUp, 55).isEmpty)
    }

    @Test func commandKeyItselfIsNeverForwarded() {
        #expect(keys(.flagsChanged, 55, flags: .command).isEmpty)
        #expect(keys(.flagsChanged, 54, flags: .command).isEmpty)
        #expect(keys(.flagsChanged, 55, flags: [], previous: .command).isEmpty)
    }

    @Test func shiftPressThenRelease() {
        #expect(keys(.flagsChanged, 56, flags: .shift) == [.mac(keyCode: 56, phase: .down)])
        #expect(keys(.flagsChanged, 56, flags: [], previous: .shift) == [.mac(keyCode: 56, phase: .up)])
    }

    @Test func leftAndRightModifiersKeepTheirKeyCodes() {
        #expect(keys(.flagsChanged, 60, flags: .shift) == [.mac(keyCode: 60, phase: .down)])
        #expect(keys(.flagsChanged, 59, flags: .control) == [.mac(keyCode: 59, phase: .down)])
        #expect(keys(.flagsChanged, 62, flags: .control) == [.mac(keyCode: 62, phase: .down)])
        #expect(keys(.flagsChanged, 58, flags: .option) == [.mac(keyCode: 58, phase: .down)])
        #expect(keys(.flagsChanged, 61, flags: [], previous: .option) == [.mac(keyCode: 61, phase: .up)])
    }

    @Test func releasingOneShiftWhileFlagStaysSetEmitsNothing() {
        #expect(keys(.flagsChanged, 56, flags: .shift, previous: .shift).isEmpty)
    }

    @Test func capsLockEmitsDownAndUpOnEveryToggle() {
        let expected: [DeviceKey] = [.mac(keyCode: 57, phase: .down), .mac(keyCode: 57, phase: .up)]
        #expect(keys(.flagsChanged, 57, flags: .capsLock) == expected)
        #expect(keys(.flagsChanged, 57, flags: [], previous: .capsLock) == expected)
    }

    @Test func fnIsIgnored() {
        #expect(keys(.flagsChanged, 63, flags: .function).isEmpty)
    }
}
