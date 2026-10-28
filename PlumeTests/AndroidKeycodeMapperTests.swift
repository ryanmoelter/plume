import AppKit
import ScrcpyControl
import Testing
@testable import Plume

/// Mac keycodes here are ANSI positions: 0 is A, 8 is C, 12 is Q, 14 is E, 18 is 1, 47 is the period, 49 is
/// space. AKEYCODE_A is 29, so AKEYCODE_C is 31 and AKEYCODE_Q is 45.
struct AndroidKeycodeMapperTests {
    private let shift = Android.Meta.shiftOn | Android.Meta.shiftLeftOn
    private let ctrl = Android.Meta.ctrlOn | Android.Meta.ctrlLeftOn

    private func map(
        _ type: KeyEventType = .keyDown,
        _ code: UInt16,
        _ flags: NSEvent.ModifierFlags = [],
        _ characters: String? = nil,
        ignoringModifiers: String? = nil
    ) -> [AndroidKeyInput]? {
        AndroidKeycodeMapper.inputs(
            type: type, keyCode: code, modifierFlags: flags,
            characters: characters, charactersIgnoringModifiers: ignoringModifiers ?? characters
        )
    }

    @Test func lettersAndSpaceGoAsKeycodesWithBothPhases() {
        #expect(map(.keyDown, 0, [], "a") == [.key(phase: .down, keycode: 29, metaState: 0)])
        #expect(map(.keyUp, 0, [], "a") == [.key(phase: .up, keycode: 29, metaState: 0)])
        #expect(map(.keyDown, 49, [], " ") == [.key(phase: .down, keycode: Android.KeyCode.space, metaState: 0)])
    }

    @Test func shiftedLettersCarryShiftMeta() {
        #expect(map(.keyDown, 0, .shift, "A") == [.key(phase: .down, keycode: 29, metaState: shift)])
    }

    @Test func capsLockLettersCarryCapsLockMeta() {
        #expect(map(.keyDown, 0, .capsLock, "A", ignoringModifiers: "a")
            == [.key(phase: .down, keycode: 29, metaState: Android.Meta.capsLockOn)])
    }

    @Test func theLetterFollowsTheLayoutNotTheKeyPosition() {
        // On AZERTY the key in QWERTY's Q position types "a".
        #expect(map(.keyDown, 12, [], "a") == [.key(phase: .down, keycode: 29, metaState: 0)])
        #expect(map(.keyDown, 0, [], "q") == [.key(phase: .down, keycode: 45, metaState: 0)])
    }

    @Test func digitsAndPunctuationGoAsTextOnKeyDownOnly() {
        #expect(map(.keyDown, 18, [], "1") == [.text("1")])
        #expect(map(.keyDown, 18, .shift, "!", ignoringModifiers: "!") == [.text("!")])
        #expect(map(.keyDown, 47, [], ".") == [.text(".")])
        #expect(map(.keyUp, 47, [], ".") == [])
    }

    @Test func accentedAndNonLatinCharactersGoAsText() {
        #expect(map(.keyDown, 19, [], "é") == [.text("é")])
        #expect(map(.keyDown, 0, [], "ф") == [.text("ф")])
    }

    @Test func aLetterKeyThatComposesSomethingElseGoesAsTextAlone() {
        #expect(map(.keyDown, 0, .option, "å", ignoringModifiers: "a") == [.text("å")])
    }

    @Test func aDeadKeySendsNothing() {
        #expect(map(.keyDown, 14, .option, "", ignoringModifiers: "e") == nil)
    }

    @Test func namedKeysGoAsKeycodesWithBothPhases() {
        #expect(map(.keyDown, 36, [], "\r") == [.key(phase: .down, keycode: Android.KeyCode.enter, metaState: 0)])
        #expect(map(.keyUp, 51, [], "\u{7F}") == [.key(phase: .up, keycode: Android.KeyCode.del, metaState: 0)])
        #expect(map(.keyDown, 123, .function, "\u{F702}") == [.key(phase: .down, keycode: Android.KeyCode.dpadLeft, metaState: 0)])
    }

    @Test func keypadEnterIsNumpadEnter() {
        // AKEYCODE_NUMPAD_ENTER.
        #expect(map(.keyDown, 76, [], "\u{3}") == [.key(phase: .down, keycode: 160, metaState: 0)])
    }

    @Test func shiftTabCarriesShiftMeta() {
        #expect(map(.keyDown, 48, .shift, "\t") == [.key(phase: .down, keycode: Android.KeyCode.tab, metaState: shift)])
    }

    @Test func controlLetterChordsGoAsKeycodes() {
        #expect(map(.keyDown, 8, .control, "\u{3}", ignoringModifiers: "c") == [.key(phase: .down, keycode: 31, metaState: ctrl)])
        #expect(map(.keyDown, 12, .control, "\u{1}", ignoringModifiers: "a") == [.key(phase: .down, keycode: 29, metaState: ctrl)])
    }

    @Test func controlWithANonLetterKeyFollowsItsCharacters() {
        #expect(map(.keyDown, 18, .control, "1") == [.text("1")])
        #expect(map(.keyDown, 33, .control, "\u{1B}", ignoringModifiers: "[") == nil)
    }

    @Test func commandChordsStayWithTheMac() {
        #expect(map(.keyDown, 9, .command, "v") == nil)
        #expect(map(.keyDown, 55, .command, nil) == nil)
    }

    @Test func releaseAfterCommandStillReachesTheDevice() {
        #expect(map(.keyUp, 125, .command, nil)
            == [.key(phase: .up, keycode: Android.KeyCode.dpadDown, metaState: Android.Meta.metaOn | Android.Meta.metaLeftOn)])
    }

    @Test func modifierChangesAndUnmappedKeysAreNotForwarded() {
        #expect(map(.flagsChanged, 56, .shift, nil) == nil)
        #expect(map(.keyDown, 122, [], "\u{F704}") == nil)
        #expect(map(.keyDown, 0, [], "") == nil)
    }

    @Test func aReleaseWhosePressWentToTheMacIsDropped() {
        var pressed = AndroidPressedKeys()
        #expect(pressed.inputs(type: .keyDown, keyCode: 0, modifierFlags: .command, characters: "a", charactersIgnoringModifiers: "a") == nil)
        #expect(pressed.inputs(type: .keyUp, keyCode: 0, modifierFlags: .command, characters: "a", charactersIgnoringModifiers: "a") == [])

        #expect(pressed.inputs(type: .keyDown, keyCode: 125, modifierFlags: [], characters: nil, charactersIgnoringModifiers: nil)
            == [.key(phase: .down, keycode: Android.KeyCode.dpadDown, metaState: 0)])
        #expect(pressed.inputs(type: .keyUp, keyCode: 125, modifierFlags: [], characters: nil, charactersIgnoringModifiers: nil)
            == [.key(phase: .up, keycode: Android.KeyCode.dpadDown, metaState: 0)])
        #expect(pressed.inputs(type: .keyUp, keyCode: 125, modifierFlags: [], characters: nil, charactersIgnoringModifiers: nil) == [])
    }

    @Test func aControlChordReleasesItsKeycodeAfterControlIsLetGo() {
        var pressed = AndroidPressedKeys()
        #expect(pressed.inputs(type: .keyDown, keyCode: 8, modifierFlags: .control, characters: "\u{3}", charactersIgnoringModifiers: "c")
            == [.key(phase: .down, keycode: 31, metaState: ctrl)])
        #expect(pressed.inputs(type: .flagsChanged, keyCode: 59, modifierFlags: [], characters: nil, charactersIgnoringModifiers: nil) == nil)
        #expect(pressed.inputs(type: .keyUp, keyCode: 8, modifierFlags: [], characters: "c", charactersIgnoringModifiers: "c")
            == [.key(phase: .up, keycode: 31, metaState: 0)])
    }

    @Test func aShiftedLetterReleasesItsKeycodeAfterShiftIsLetGo() {
        var pressed = AndroidPressedKeys()
        #expect(pressed.inputs(type: .keyDown, keyCode: 0, modifierFlags: .shift, characters: "A", charactersIgnoringModifiers: "A")
            == [.key(phase: .down, keycode: 29, metaState: shift)])
        #expect(pressed.inputs(type: .keyUp, keyCode: 0, modifierFlags: [], characters: "a", charactersIgnoringModifiers: "a")
            == [.key(phase: .up, keycode: 29, metaState: 0)])
    }

    @Test func autoRepeatCountsUpUntilTheKeyIsReleased() {
        var pressed = AndroidPressedKeys()
        let down = { (isRepeat: Bool) in
            pressed.inputs(type: .keyDown, keyCode: 0, modifierFlags: [], characters: "a", charactersIgnoringModifiers: "a", isRepeat: isRepeat)
        }
        #expect(down(false) == [.key(phase: .down, keycode: 29, metaState: 0, repeatCount: 0)])
        #expect(down(true) == [.key(phase: .down, keycode: 29, metaState: 0, repeatCount: 1)])
        #expect(down(true) == [.key(phase: .down, keycode: 29, metaState: 0, repeatCount: 2)])
        #expect(pressed.inputs(type: .keyUp, keyCode: 0, modifierFlags: [], characters: "a", charactersIgnoringModifiers: "a")
            == [.key(phase: .up, keycode: 29, metaState: 0)])
        #expect(down(false) == [.key(phase: .down, keycode: 29, metaState: 0, repeatCount: 0)])
    }

    @Test func aRepeatedTextKeySendsTheTextAgain() {
        var pressed = AndroidPressedKeys()
        #expect(pressed.inputs(type: .keyDown, keyCode: 47, modifierFlags: [], characters: ".", charactersIgnoringModifiers: ".") == [.text(".")])
        #expect(pressed.inputs(type: .keyDown, keyCode: 47, modifierFlags: [], characters: ".", charactersIgnoringModifiers: ".", isRepeat: true)
            == [.text(".")])
    }

    @Test func textKeysSendNothingOnRelease() {
        var pressed = AndroidPressedKeys()
        #expect(pressed.inputs(type: .keyDown, keyCode: 47, modifierFlags: [], characters: ".", charactersIgnoringModifiers: ".") == [.text(".")])
        #expect(pressed.inputs(type: .keyUp, keyCode: 47, modifierFlags: [], characters: ".", charactersIgnoringModifiers: ".") == [])
    }

    @Test func metaStateCombinesModifiers() {
        let meta = AndroidKeycodeMapper.metaState([.shift, .option, .capsLock])
        #expect(meta == Android.Meta.shiftOn | Android.Meta.shiftLeftOn | Android.Meta.altOn | Android.Meta.altLeftOn | Android.Meta.capsLockOn)
    }
}
