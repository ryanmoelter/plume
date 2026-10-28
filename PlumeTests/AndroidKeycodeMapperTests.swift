import AppKit
import ScrcpyControl
import Testing
@testable import Plume

struct AndroidKeycodeMapperTests {
    private func map(
        _ type: KeyEventType = .keyDown,
        _ code: UInt16,
        _ flags: NSEvent.ModifierFlags = [],
        _ characters: String? = nil
    ) -> [AndroidKeyInput]? {
        AndroidKeycodeMapper.inputs(type: type, keyCode: code, modifierFlags: flags, characters: characters)
    }

    @Test func printableKeysGoAsTextOnKeyDownOnly() {
        #expect(map(.keyDown, 0, [], "a") == [.text("a")])
        #expect(map(.keyUp, 0, [], "a") == [])
    }

    @Test func textFollowsTheMacLayout() {
        #expect(map(.keyDown, 0, .shift, "Q") == [.text("Q")])
        #expect(map(.keyDown, 14, .option, "´") == [.text("´")])
    }

    @Test func namedKeysGoAsKeycodesWithBothPhases() {
        #expect(map(.keyDown, 36, [], "\r") == [.key(phase: .down, keycode: Android.KeyCode.enter, metaState: 0)])
        #expect(map(.keyUp, 51, [], "\u{7F}") == [.key(phase: .up, keycode: Android.KeyCode.del, metaState: 0)])
        #expect(map(.keyDown, 123, .function, "\u{F702}") == [.key(phase: .down, keycode: Android.KeyCode.dpadLeft, metaState: 0)])
    }

    @Test func shiftTabCarriesShiftMeta() {
        let meta = Android.Meta.shiftOn | Android.Meta.shiftLeftOn
        #expect(map(.keyDown, 48, .shift, "\t") == [.key(phase: .down, keycode: Android.KeyCode.tab, metaState: meta)])
    }

    @Test func controlChordsGoAsKeycodes() {
        let meta = Android.Meta.ctrlOn | Android.Meta.ctrlLeftOn
        // Mac keycode 8 is C; AKEYCODE_C is 31.
        #expect(map(.keyDown, 8, .control, "\u{3}") == [.key(phase: .down, keycode: 31, metaState: meta)])
        // Mac keycode 29 is 0; AKEYCODE_0 is 7.
        #expect(map(.keyDown, 29, .control, "0") == [.key(phase: .down, keycode: 7, metaState: meta)])
    }

    @Test func commandChordsStayWithTheMac() {
        #expect(map(.keyDown, 9, .command, "v") == nil)
        #expect(map(.keyDown, 55, .command, nil) == nil)
    }

    @Test func releaseAfterCommandStillReachesTheDevice() {
        #expect(map(.keyUp, 125, .command, nil) == [.key(phase: .up, keycode: Android.KeyCode.dpadDown, metaState: 0)])
    }

    @Test func modifierChangesAndUnmappedKeysAreNotForwarded() {
        #expect(map(.flagsChanged, 56, .shift, nil) == nil)
        #expect(map(.keyDown, 122, [], "\u{F704}") == nil)
        #expect(map(.keyDown, 0, [], "") == nil)
    }

    @Test func aReleaseWhosePressWentToTheMacIsDropped() {
        var pressed = AndroidPressedKeys()
        #expect(pressed.inputs(type: .keyDown, keyCode: 125, modifierFlags: .command, characters: nil) == nil)
        #expect(pressed.inputs(type: .keyUp, keyCode: 125, modifierFlags: .command, characters: nil) == [])

        #expect(pressed.inputs(type: .keyDown, keyCode: 125, modifierFlags: [], characters: nil)
            == [.key(phase: .down, keycode: Android.KeyCode.dpadDown, metaState: 0)])
        #expect(pressed.inputs(type: .keyUp, keyCode: 125, modifierFlags: [], characters: nil)
            == [.key(phase: .up, keycode: Android.KeyCode.dpadDown, metaState: 0)])
        #expect(pressed.inputs(type: .keyUp, keyCode: 125, modifierFlags: [], characters: nil) == [])
    }

    @Test func aControlChordReleasesItsKeycodeAfterControlIsLetGo() {
        var pressed = AndroidPressedKeys()
        let meta = Android.Meta.ctrlOn | Android.Meta.ctrlLeftOn
        // Mac keycode 8 is C; AKEYCODE_C is 31.
        #expect(pressed.inputs(type: .keyDown, keyCode: 8, modifierFlags: .control, characters: "\u{3}")
            == [.key(phase: .down, keycode: 31, metaState: meta)])
        #expect(pressed.inputs(type: .flagsChanged, keyCode: 59, modifierFlags: [], characters: nil) == nil)
        #expect(pressed.inputs(type: .keyUp, keyCode: 8, modifierFlags: [], characters: "c")
            == [.key(phase: .up, keycode: 31, metaState: 0)])
    }

    @Test func autoRepeatCountsUpUntilTheKeyIsReleased() {
        var pressed = AndroidPressedKeys()
        let down = { (isRepeat: Bool) in
            pressed.inputs(type: .keyDown, keyCode: 125, modifierFlags: [], characters: nil, isRepeat: isRepeat)
        }
        #expect(down(false) == [.key(phase: .down, keycode: Android.KeyCode.dpadDown, metaState: 0, repeatCount: 0)])
        #expect(down(true) == [.key(phase: .down, keycode: Android.KeyCode.dpadDown, metaState: 0, repeatCount: 1)])
        #expect(down(true) == [.key(phase: .down, keycode: Android.KeyCode.dpadDown, metaState: 0, repeatCount: 2)])
        #expect(pressed.inputs(type: .keyUp, keyCode: 125, modifierFlags: [], characters: nil)
            == [.key(phase: .up, keycode: Android.KeyCode.dpadDown, metaState: 0)])
        #expect(down(false) == [.key(phase: .down, keycode: Android.KeyCode.dpadDown, metaState: 0, repeatCount: 0)])
    }

    @Test func textKeysSendNothingOnRelease() {
        var pressed = AndroidPressedKeys()
        #expect(pressed.inputs(type: .keyDown, keyCode: 0, modifierFlags: [], characters: "a") == [.text("a")])
        #expect(pressed.inputs(type: .keyUp, keyCode: 0, modifierFlags: [], characters: "a") == [])
    }

    @Test func metaStateCombinesModifiers() {
        let meta = AndroidKeycodeMapper.metaState([.shift, .option, .capsLock])
        #expect(meta == Android.Meta.shiftOn | Android.Meta.shiftLeftOn | Android.Meta.altOn | Android.Meta.altLeftOn | Android.Meta.capsLockOn)
    }
}
