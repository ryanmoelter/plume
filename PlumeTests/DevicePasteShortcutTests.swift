import AppKit
import EmulatorControl
import Foundation
import Testing
@testable import Plume

@MainActor
struct DevicePasteShortcutTests {
    @Test func commandVIsThePasteChord() {
        #expect(DevicePasteShortcut.matches(characters: "v", flags: .command))
        #expect(DevicePasteShortcut.matches(characters: "v", flags: [.command, .capsLock]))
        #expect(DevicePasteShortcut.matches(characters: "V", flags: [.command, .capsLock]))
    }

    @Test func otherChordsAreNotThePasteChord() {
        #expect(!DevicePasteShortcut.matches(characters: "v", flags: []))
        #expect(!DevicePasteShortcut.matches(characters: "v", flags: [.command, .shift]))
        #expect(!DevicePasteShortcut.matches(characters: "v", flags: [.command, .option]))
        #expect(!DevicePasteShortcut.matches(characters: "v", flags: [.command, .control]))
        #expect(!DevicePasteShortcut.matches(characters: "v", flags: .control))
        #expect(!DevicePasteShortcut.matches(characters: "c", flags: .command))
        #expect(!DevicePasteShortcut.matches(characters: nil, flags: .command))
    }

    @Test func commandVPastesAndARepeatOnlyReleasesKeys() {
        #expect(DevicePasteShortcut.action(characters: "v", flags: .command, isRepeat: false) == .paste)
        #expect(DevicePasteShortcut.action(characters: "v", flags: .command, isRepeat: true) == .releaseKeysOnly)
        #expect(DevicePasteShortcut.action(characters: "v", flags: [.command, .shift], isRepeat: false) == nil)
        #expect(DevicePasteShortcut.action(characters: "c", flags: .command, isRepeat: false) == nil)
    }

    @Test func pasteTextIsNilWithoutText() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("DevicePasteShortcutTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        #expect(DevicePasteShortcut.text(from: pasteboard) == nil)

        pasteboard.setString("", forType: .string)
        #expect(DevicePasteShortcut.text(from: pasteboard) == nil)

        pasteboard.clearContents()
        pasteboard.setData(Data([0x89, 0x50]), forType: .png)
        #expect(DevicePasteShortcut.text(from: pasteboard) == nil)

        pasteboard.clearContents()
        pasteboard.setString("héllo\nworld", forType: .string)
        #expect(DevicePasteShortcut.text(from: pasteboard) == "héllo\nworld")
    }

    @Test func emulatorPasteIsControlV() {
        #expect(EmulatorKeyMapper.pasteChord == [
            .evdev(keyCode: 29, phase: .down),
            .evdev(keyCode: 47, phase: .down),
            .evdev(keyCode: 47, phase: .up),
            .evdev(keyCode: 29, phase: .up),
        ])
    }

    @Test func emulatorClipboardTextIsCutOnACharacterBoundary() {
        let max = EmulatorConnection.clipboardTextMaxBytes
        let fits = String(repeating: "a", count: max)
        #expect(EmulatorConnection.clipboardText(fits) == fits)
        #expect(EmulatorConnection.clipboardText(fits + "b").utf8.count == max)
        let split = String(repeating: "a", count: max - 1) + "é"
        #expect(EmulatorConnection.clipboardText(split) == String(repeating: "a", count: max - 1))
    }
}

/// Input sent while a paste waits on the clipboard queues behind it, in order, and a second paste
/// waits for the first to finish.
struct EmulatorInputOrderTests {
    private typealias Order = EmulatorInputOrder<Int>

    private func describe(_ steps: [Order.Step]) -> [String] {
        steps.map { step in
            switch step {
            case .deliver(let input): "input \(input)"
            case .startPaste(let text): "paste \(text)"
            }
        }
    }

    @Test func inputPassesStraightThroughWithNoPastePending() {
        var order = Order()
        #expect(describe(order.input(1)) == ["input 1"])
        #expect(describe(order.input(2)) == ["input 2"])
    }

    @Test func inputSentDuringAPasteWaitsForIt() {
        var order = Order()
        #expect(describe(order.paste("A")) == ["paste A"])
        #expect(order.input(1).isEmpty)
        #expect(order.input(2).isEmpty)
        #expect(describe(order.pasteFinished()) == ["input 1", "input 2"])
        #expect(describe(order.input(3)) == ["input 3"])
    }

    @Test func successivePastesRunOneAfterAnother() {
        var order = Order()
        #expect(describe(order.paste("A")) == ["paste A"])
        #expect(order.paste("B").isEmpty)
        #expect(order.input(1).isEmpty)
        #expect(describe(order.pasteFinished()) == ["paste B"])
        #expect(order.input(2).isEmpty)
        #expect(describe(order.pasteFinished()) == ["input 1", "input 2"])
        #expect(describe(order.paste("C")) == ["paste C"])
    }

    @Test func inputBetweenPastesKeepsItsPlace() {
        var order = Order()
        _ = order.paste("A")
        _ = order.input(1)
        _ = order.paste("B")
        _ = order.input(2)
        #expect(describe(order.pasteFinished()) == ["input 1", "paste B"])
        #expect(describe(order.pasteFinished()) == ["input 2"])
    }
}
