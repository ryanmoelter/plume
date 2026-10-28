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
        #expect(map(.keyDown, 125, .command, nil) == nil)
        #expect(pressed.filter(map(.keyUp, 125, .command, nil)!) == [])

        let down = AndroidKeyInput.key(phase: .down, keycode: Android.KeyCode.dpadDown, metaState: 0)
        let up = AndroidKeyInput.key(phase: .up, keycode: Android.KeyCode.dpadDown, metaState: 0)
        #expect(pressed.filter([down]) == [down])
        #expect(pressed.filter([up]) == [up])
        #expect(pressed.filter([up]) == [])
        #expect(pressed.filter([.text("a")]) == [.text("a")])
    }

    @Test func metaStateCombinesModifiers() {
        let meta = AndroidKeycodeMapper.metaState([.shift, .option, .capsLock])
        #expect(meta == Android.Meta.shiftOn | Android.Meta.shiftLeftOn | Android.Meta.altOn | Android.Meta.altLeftOn | Android.Meta.capsLockOn)
    }
}
