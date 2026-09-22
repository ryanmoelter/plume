import AppKit
import SwiftUI
import Testing
@testable import Plume

/// Pins how AppKit matches a menu item's key equivalent against a real key
/// event, for the chord shapes `ShortcutAction` can be bound to.
///
/// A rebindable chord is only useful if `performKeyEquivalent` fires it, and
/// that match reads the event's *composed* characters — which an Option chord
/// changes. These tests hold an item against events built the way the window
/// server builds them.
@MainActor
@Suite struct MenuKeyEquivalentTests {
    /// `NSMenuItem.target` is weak, so a test has to hold this itself.
    private final class Target: NSObject {
        var fired = false
        @objc func fire() { fired = true }
    }

    private func menu(for shortcut: MenuShortcut, target: Target) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let item = NSMenuItem(
            title: "Next Tab", action: #selector(Target.fire), keyEquivalent: String(shortcut.key)
        )
        item.keyEquivalentModifierMask = MenuShortcut.appKitFlags(shortcut.modifiers)
        item.target = target
        item.isEnabled = true
        menu.addItem(item)
        return menu
    }

    /// `characters` is what the layout composes; `charactersIgnoringModifiers`
    /// is the key's label. The window server sets both.
    private func event(key: Character, composed: String, flags: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: 0, context: nil, characters: composed,
            charactersIgnoringModifiers: String(key), isARepeat: false,
            keyCode: UInt16(SyntheticKey.keyCode(for: key) ?? 0)
        )!
    }

    private func fires(_ shortcut: MenuShortcut, composed: String, flags: NSEvent.ModifierFlags) -> Bool {
        let target = Target()
        let menu = menu(for: shortcut, target: target)
        _ = menu.performKeyEquivalent(with: event(key: shortcut.key, composed: composed, flags: flags))
        return target.fired
    }

    @Test func commandChordFires() {
        #expect(fires(MenuShortcut("j"), composed: "j", flags: .command))
    }

    @Test func commandOptionChordFires() {
        #expect(fires(MenuShortcut("j", modifiers: [.command, .option]), composed: "j", flags: [.command, .option]))
    }

    /// The bug PLUME-49 shipped with. An Option chord composes to another
    /// character, and AppKit matches a key equivalent against that composed
    /// character, so a bare Option chord never reaches its item.
    @Test func bareOptionChordMissesTheItemItComposesAwayFrom() {
        #expect(!fires(MenuShortcut("j", modifiers: [.option]), composed: "∆", flags: .option))
    }
}
