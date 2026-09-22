import AppKit

/// Writes the rebindable chords onto the menu items AppKit actually
/// dispatches.
///
/// SwiftUI builds `PlumeCommands` into an `NSMenu` once and never rebuilds it
/// for a changed binding: a `Commands` body is not re-evaluated by observation
/// the way a `View` body is, so a chord recorded in Settings reached the menu
/// only on the next launch. Every recorded chord did nothing, and the chord it
/// replaced kept working. Setting `keyEquivalent` on the built item is what
/// makes a rebind take effect at once.
///
/// Items are found by title, which is what SwiftUI leaves to identify them by
/// — a `Commands` `Button` carries no tag or identifier into AppKit.
@MainActor
enum ShortcutMenuApplier {
    /// Applies `bindings` to `menu`, and reports the actions whose item was
    /// found. A caller can compare that against `ShortcutAction.allCases` to
    /// notice a title that drifted out of step.
    @discardableResult
    static func apply(_ bindings: ShortcutBindings, to menu: NSMenu) -> Set<ShortcutAction> {
        var applied: Set<ShortcutAction> = []
        for action in ShortcutAction.allCases {
            guard let item = item(titled: action.label, in: menu) else { continue }
            applied.insert(action)
            if let shortcut = bindings[action] {
                item.keyEquivalent = String(shortcut.key)
                item.keyEquivalentModifierMask = MenuShortcut.appKitFlags(shortcut.modifiers)
            } else {
                item.keyEquivalent = ""
                item.keyEquivalentModifierMask = []
            }
        }
        return applied
    }

    static func item(titled title: String, in menu: NSMenu) -> NSMenuItem? {
        for candidate in menu.items {
            if candidate.title == title, candidate.submenu == nil { return candidate }
            if let submenu = candidate.submenu, let found = item(titled: title, in: submenu) { return found }
        }
        return nil
    }
}
