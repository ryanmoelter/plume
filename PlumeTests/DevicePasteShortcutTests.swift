import AppKit
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
}
