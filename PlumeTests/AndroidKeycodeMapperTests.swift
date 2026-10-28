import AppKit
import ScrcpyControl
import SwiftUI
import Testing
@testable import Plume

/// Mac keycodes here are ANSI positions: 0 is A, 8 is C, 12 is Q, 14 is E, 18 is 1, 47 is the period, 49 is
/// space. AKEYCODE_A is 29, so AKEYCODE_C is 31 and AKEYCODE_Q is 45.
@MainActor
struct AndroidKeycodeMapperTests {
    private let shift = Android.Meta.shiftOn | Android.Meta.shiftLeftOn
    private let ctrl = Android.Meta.ctrlOn | Android.Meta.ctrlLeftOn
    private let alt = Android.Meta.altOn | Android.Meta.altLeftOn
    private let meta = Android.Meta.metaOn | Android.Meta.metaLeftOn

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

    @Test func aLetterKeyThatComposesSomethingElseSendsTheKeycodeAndTheText() {
        #expect(map(.keyDown, 0, .option, "å", ignoringModifiers: "a")
            == [.key(phase: .down, keycode: 29, metaState: alt), .text("å")])
    }

    @Test func aDeadKeySendsOnlyItsKeycode() {
        // Option-E, then E: the composed "é" arrives with the second key.
        #expect(map(.keyDown, 14, .option, "", ignoringModifiers: "e") == [.key(phase: .down, keycode: 33, metaState: alt)])
        #expect(map(.keyDown, 14, [], "é", ignoringModifiers: "e") == [.key(phase: .down, keycode: 33, metaState: 0), .text("é")])
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

    @Test func commandChordsCarryMetaAndSendNoText() {
        #expect(map(.keyDown, 9, .command, "v") == [.key(phase: .down, keycode: 50, metaState: meta)])
        #expect(map(.keyDown, 18, .command, "1") == nil)
    }

    @Test func releaseAfterCommandStillReachesTheDevice() {
        #expect(map(.keyUp, 125, .command, nil)
            == [.key(phase: .up, keycode: Android.KeyCode.dpadDown, metaState: Android.Meta.metaOn | Android.Meta.metaLeftOn)])
    }

    @Test func functionKeysAndEmptyCharactersAreNotForwarded() {
        #expect(map(.keyDown, 122, [], "\u{F704}") == nil)
        #expect(map(.keyDown, 0, [], "") == nil)
    }

    @Test func aReleaseWithNoForwardedPressSendsNothing() {
        var pressed = AndroidPressedKeys()
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
            == [.key(phase: .down, keycode: 113, metaState: ctrl), .key(phase: .down, keycode: 31, metaState: ctrl)])
        #expect(pressed.inputs(type: .flagsChanged, keyCode: 59, modifierFlags: [], characters: nil, charactersIgnoringModifiers: nil)
            == [.key(phase: .up, keycode: 113, metaState: 0)])
        #expect(pressed.inputs(type: .keyUp, keyCode: 8, modifierFlags: [], characters: "c", charactersIgnoringModifiers: "c")
            == [.key(phase: .up, keycode: 31, metaState: 0)])
    }

    @Test func aShiftedLetterReleasesItsKeycodeAfterShiftIsLetGo() {
        var pressed = AndroidPressedKeys()
        #expect(pressed.inputs(type: .flagsChanged, keyCode: 56, modifierFlags: .shift, characters: nil, charactersIgnoringModifiers: nil)
            == [.key(phase: .down, keycode: 59, metaState: shift)])
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

    // MARK: Modifiers

    /// `NX_DEVICE…KEYMASK` bits, as a real event carries them alongside the generic flag.
    private func flags(_ generic: NSEvent.ModifierFlags, device: UInt) -> NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: generic.rawValue | device)
    }

    private func modifier(_ pressed: inout AndroidPressedKeys, _ code: UInt16, _ flags: NSEvent.ModifierFlags) -> [AndroidKeyInput]? {
        pressed.inputs(type: .flagsChanged, keyCode: code, modifierFlags: flags, characters: nil, charactersIgnoringModifiers: nil)
    }

    @Test func modifierPressesGoOnTheirOwn() {
        var pressed = AndroidPressedKeys()
        #expect(modifier(&pressed, 55, flags(.command, device: 0x08)) == [.key(phase: .down, keycode: 117, metaState: meta)])
        #expect(modifier(&pressed, 55, []) == [.key(phase: .up, keycode: 117, metaState: 0)])
        #expect(modifier(&pressed, 58, flags(.option, device: 0x20)) == [.key(phase: .down, keycode: 57, metaState: alt)])
    }

    @Test func rightSideModifiersSendTheirOwnKeycodeAndMetaBit() {
        var pressed = AndroidPressedKeys()
        let rightMeta = Android.Meta.metaOn | Android.Meta.metaRightOn
        #expect(modifier(&pressed, 54, flags(.command, device: 0x10)) == [.key(phase: .down, keycode: 118, metaState: rightMeta)])
        #expect(modifier(&pressed, 61, flags([.command, .option], device: 0x10 | 0x40))
            == [.key(phase: .down, keycode: 58, metaState: rightMeta | Android.Meta.altOn | Android.Meta.altRightOn)])
    }

    @Test func releasingOneShiftWhileTheOtherIsHeldReleasesOnlyThatSide() {
        var pressed = AndroidPressedKeys()
        _ = modifier(&pressed, 56, flags(.shift, device: 0x02))
        _ = modifier(&pressed, 60, flags(.shift, device: 0x02 | 0x04))
        #expect(modifier(&pressed, 56, flags(.shift, device: 0x04))
            == [.key(phase: .up, keycode: 59, metaState: Android.Meta.shiftOn | Android.Meta.shiftRightOn)])
    }

    @Test func capsLockAndFnKeysAreNotForwardedOnTheirOwn() {
        var pressed = AndroidPressedKeys()
        #expect(modifier(&pressed, 57, .capsLock) == nil)
        #expect(modifier(&pressed, 63, .function) == nil)
    }

    @Test func aCommandChordSendsMetaThenTheKeyAndPairsEveryRelease() {
        var pressed = AndroidPressedKeys()
        let cmd = flags(.command, device: 0x08)
        #expect(modifier(&pressed, 55, cmd) == [.key(phase: .down, keycode: 117, metaState: meta)])
        #expect(pressed.inputs(type: .keyDown, keyCode: 0, modifierFlags: cmd, characters: "a", charactersIgnoringModifiers: "a")
            == [.key(phase: .down, keycode: 29, metaState: meta)])
        #expect(pressed.inputs(type: .keyUp, keyCode: 0, modifierFlags: cmd, characters: "a", charactersIgnoringModifiers: "a")
            == [.key(phase: .up, keycode: 29, metaState: meta)])
        #expect(modifier(&pressed, 55, []) == [.key(phase: .up, keycode: 117, metaState: 0)])
        #expect(pressed.isEmpty)
    }

    @Test func aModifierHeldBeforeFocusGoesDownWithTheNextKey() {
        var pressed = AndroidPressedKeys()
        #expect(pressed.inputs(type: .keyDown, keyCode: 0, modifierFlags: flags(.command, device: 0x08), characters: "a", charactersIgnoringModifiers: "a")
            == [.key(phase: .down, keycode: 117, metaState: meta), .key(phase: .down, keycode: 29, metaState: meta)])
    }

    // MARK: Plume shortcuts

    @Test func releaseAllLiftsKeysThenModifiersWithMetaLast() {
        var pressed = AndroidPressedKeys()
        let held = flags([.command, .shift], device: 0x08 | 0x02)
        _ = modifier(&pressed, 55, flags(.command, device: 0x08))
        _ = modifier(&pressed, 56, held)
        _ = pressed.inputs(type: .keyDown, keyCode: 125, modifierFlags: held, characters: nil, charactersIgnoringModifiers: nil)
        #expect(pressed.releaseAll() == [
            .key(phase: .up, keycode: Android.KeyCode.dpadDown, metaState: meta | shift),
            .key(phase: .up, keycode: 59, metaState: meta),
            .key(phase: .up, keycode: 117, metaState: 0),
        ])
        #expect(pressed.isEmpty)
        #expect(pressed.inputs(type: .keyUp, keyCode: 125, modifierFlags: [], characters: nil, charactersIgnoringModifiers: nil) == [])
        #expect(modifier(&pressed, 55, []) == [])
    }

    @Test func releasingALoneMetaSendsAControlTapFirstSoAndroidOpensNoAllApps() {
        var pressed = AndroidPressedKeys()
        _ = modifier(&pressed, 55, flags(.command, device: 0x08))
        #expect(pressed.releaseAll() == [
            .key(phase: .down, keycode: 113, metaState: meta | ctrl),
            .key(phase: .up, keycode: 113, metaState: meta),
            .key(phase: .up, keycode: 117, metaState: 0),
        ])
        #expect(pressed.releaseAll() == [])
    }

    @Test func aCommandKeyDownAfterReleaseAllPressesMetaAgain() {
        var pressed = AndroidPressedKeys()
        let cmd = flags(.command, device: 0x08)
        _ = modifier(&pressed, 55, cmd)
        _ = pressed.releaseAll()
        #expect(pressed.inputs(type: .keyDown, keyCode: 0, modifierFlags: cmd, characters: "a", charactersIgnoringModifiers: "a")
            == [.key(phase: .down, keycode: 117, metaState: meta), .key(phase: .down, keycode: 29, metaState: meta)])
    }

    private func keepsOnMac(_ characters: String, _ flags: NSEvent.ModifierFlags, keepsPlumeShortcuts: Bool = true) -> Bool {
        let plume: [MenuShortcut] = [MenuShortcut("t"), MenuShortcut("j", modifiers: .option)]
        return AndroidShortcutPolicy.keepsOnMac(
            characters: characters, flags: flags, keepsPlumeShortcuts: keepsPlumeShortcuts,
            isPlumeShortcut: { characters, flags in plume.contains { $0.matches(characters: characters, flags: flags) } }
        )
    }

    @Test func plumeShortcutsStayOnTheMacAndOtherCommandChordsGoToTheDevice() {
        #expect(keepsOnMac("t", .command))
        #expect(!keepsOnMac("k", .command))
        #expect(!keepsOnMac("t", [.command, .shift]))
    }

    @Test func turningTheSettingOffSendsEveryCommandChordToTheDevice() {
        #expect(!keepsOnMac("t", .command, keepsPlumeShortcuts: false))
        #expect(keepsOnMac("j", .option, keepsPlumeShortcuts: false))
    }
}
