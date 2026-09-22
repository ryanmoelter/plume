import AppKit
import os

/// Gives the menu bar first refusal on Plume's own shortcuts, so they still
/// work while a terminal surface holds keyboard focus.
///
/// A focused ghostty surface consumes Command chords before the menu ever sees
/// them: `AppTerminalView.performKeyEquivalent` claims any chord the user's
/// ghostty config binds (`cmd+t`, `cmd+w` and `cmd+1`…`cmd+9` are common
/// defaults), and AppKit offers the key window's views their
/// `performKeyEquivalent` *before* the main menu's. Whatever the surface takes
/// there never reaches `PlumeCommands`.
///
/// A local `.keyDown` monitor runs ahead of that dispatch, which is the only
/// place to intervene without editing the pinned package's view.
@MainActor
final class TerminalShortcutMonitor {
    static let shared = TerminalShortcutMonitor()

    private var monitor: Any?

    private init() {}

    /// Installs the monitor, once. Safe to call repeatedly; later calls are
    /// no-ops, so no launch path can end up with two monitors racing to claim
    /// the same event.
    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handle(event) ? nil : event
        }
    }

    func uninstall() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
    }

    /// Returns whether the event was consumed. Anything not consumed is
    /// returned to AppKit untouched, so every key Plume does not bind reaches
    /// the terminal exactly as before.
    private func handle(_ event: NSEvent) -> Bool {
        Log.app.notice("shortcut monitor saw \(event.charactersIgnoringModifiers ?? "?", privacy: .public)")
        guard Self.isClaimed(characters: event.charactersIgnoringModifiers, flags: event.modifierFlags)
        else { return false }

        // `performKeyEquivalent` respects each item's `disabled` state, so a
        // command with no selected task declines here and the chord falls
        // through to the terminal rather than vanishing.
        let handled = NSApp.mainMenu?.performKeyEquivalent(with: event) ?? false
        Log.app.notice(
            "shortcut monitor claimed \(event.charactersIgnoringModifiers ?? "?", privacy: .public), menu handled: \(handled, privacy: .public)"
        )
        return handled
    }

    /// Whether this chord is one `PlumeCommands` binds, and so one the menu
    /// should be offered ahead of the terminal.
    ///
    /// Derived from `PlumeShortcuts.all` rather than a list of its own, and
    /// narrowed to Command-bearing chords by `MenuShortcut.isClaimable` — the
    /// terminal keeps every bare key, every Control chord, and every Option
    /// chord that Command does not also cover.
    static func isClaimed(characters: String?, flags: NSEvent.ModifierFlags) -> Bool {
        PlumeShortcuts.all.contains { $0.matches(characters: characters, flags: flags) }
    }
}
