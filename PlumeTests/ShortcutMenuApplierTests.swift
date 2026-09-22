import AppKit
import SwiftUI
import Testing
@testable import Plume

/// Covers the step that makes a rebind take effect without a relaunch: the
/// chord is written onto the `NSMenuItem` SwiftUI already built.
@MainActor
struct ShortcutMenuApplierTests {
    /// The shape SwiftUI leaves behind — a "Tab" submenu holding one item per
    /// rebindable action, titled with `ShortcutAction.label`.
    private func tabMenu() -> NSMenu {
        let root = NSMenu()
        let tab = NSMenuItem(title: "Tab", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Tab")
        for action in ShortcutAction.allCases {
            submenu.addItem(NSMenuItem(title: action.label, action: nil, keyEquivalent: ""))
        }
        tab.submenu = submenu
        root.addItem(tab)
        return root
    }

    private func item(_ action: ShortcutAction, in menu: NSMenu) -> NSMenuItem? {
        ShortcutMenuApplier.item(titled: action.label, in: menu)
    }

    @Test func everyRebindableActionFindsItsItem() {
        #expect(ShortcutMenuApplier.apply(ShortcutBindings(), to: tabMenu()) == Set(ShortcutAction.allCases))
    }

    @Test func defaultsReachTheItems() {
        let menu = tabMenu()
        ShortcutMenuApplier.apply(ShortcutBindings(), to: menu)
        for action in ShortcutAction.allCases {
            let found = item(action, in: menu)
            #expect(found?.keyEquivalent == String(action.defaultShortcut.key))
            #expect(found?.keyEquivalentModifierMask == MenuShortcut.appKitFlags(action.defaultShortcut.modifiers))
        }
    }

    @Test func aRebindReplacesTheChordOnTheBuiltItem() {
        let menu = tabMenu()
        ShortcutMenuApplier.apply(ShortcutBindings(), to: menu)

        var bindings = ShortcutBindings()
        bindings.assign(MenuShortcut("j", modifiers: [.option]), to: .nextTab)
        ShortcutMenuApplier.apply(bindings, to: menu)

        let nextTab = item(.nextTab, in: menu)
        #expect(nextTab?.keyEquivalent == "j")
        #expect(nextTab?.keyEquivalentModifierMask == [.option])
    }

    /// An action left unbound because another took its chord must lose the
    /// chord on the item too, or the menu keeps dispatching the old one.
    @Test func anUnboundActionLosesItsChord() {
        let menu = tabMenu()
        ShortcutMenuApplier.apply(ShortcutBindings(), to: menu)

        var bindings = ShortcutBindings()
        bindings.assign(ShortcutAction.nextTab.defaultShortcut, to: .previousTab)
        ShortcutMenuApplier.apply(bindings, to: menu)

        #expect(bindings[.nextTab] == nil)
        #expect(item(.nextTab, in: menu)?.keyEquivalent == "")
        #expect(item(.nextTab, in: menu)?.keyEquivalentModifierMask == [])
    }

    @Test func aMenuMissingAnItemReportsWhichActionsApplied() {
        let menu = tabMenu()
        let submenu = menu.items[0].submenu!
        submenu.removeItem(ShortcutMenuApplier.item(titled: ShortcutAction.nextTask.label, in: menu)!)
        let applied = ShortcutMenuApplier.apply(ShortcutBindings(), to: menu)
        #expect(!applied.contains(.nextTask))
        #expect(applied.contains(.nextTab))
    }
}
