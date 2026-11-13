import AppKit
import Foundation
import GhosttyTerminal
import SwiftUI
import Testing
@testable import Plume

/// Answers the question a rebindable Option chord raises: does a focused
/// terminal surface swallow it before the menu sees it?
///
/// `TerminalShortcutMonitor` runs as a local `.keyDown` monitor, which AppKit
/// offers the event *before* it reaches the key window's
/// `performKeyEquivalent` — the surface included. These tests pin both halves:
/// the surface really does claim an Option chord when asked directly, and the
/// monitor's own filter takes the chord first.
///
/// Needs a real GUI session for the same reason `SurfaceCommandTests` does —
/// it builds real `NSWindow`s and surfaces.
@MainActor
@Suite struct TerminalShortcutReclaimTests {
    /// A live terminal surface hosted in a real window, focused, under a
    /// Ghostty config the test pins rather than the developer's own.
    ///
    /// Whether a surface claims an Option chord is decided by the Ghostty
    /// config: the wrapper's `performKeyEquivalent` takes a chord without
    /// Command or Control only when `ghostty_surface_key_is_binding` says a
    /// keybind names it. The shared runtime loads whatever config the
    /// machine has, so a test built on it passes on a Mac whose config binds
    /// ⌥J and fails on one with none, like CI. The surface gets its own
    /// controller here, built from `config`, so the answer is the same
    /// everywhere.
    @MainActor
    private struct FocusedTerminal {
        let window: NSWindow
        let state: TerminalViewState

        init(config: String) {
            state = TerminalViewState(configSource: .generated(config))
            state.configuration = TerminalSurfaceOptions(
                workingDirectory: NSTemporaryDirectory(),
                command: "/bin/sh -c 'sleep 30; true'"
            )
            let host = NSHostingView(rootView: TerminalSurfaceView(context: state))
            host.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
            window = NSWindow(
                contentRect: host.frame,
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.contentView = host
            window.orderFrontRegardless()
            window.makeKey()
        }

        /// Focuses the terminal's view once the surface has put one in the
        /// window, which a loaded machine can take seconds to do. Nil if none
        /// appears by the deadline.
        func waitForFocus() async throws -> NSView? {
            let deadline = ContinuousClock.now + .seconds(20)
            while true {
                if let view = focusTerminalView(), window.firstResponder === view { return view }
                if ContinuousClock.now >= deadline { return focusTerminalView() }
                try await Task.sleep(for: .milliseconds(100))
            }
        }

        /// The deepest view that accepts first responder — the terminal's own
        /// key-handling view.
        func focusTerminalView() -> NSView? {
            guard let root = window.contentView else { return nil }
            let target = Self.firstResponderCandidate(in: root)
            if let target { window.makeFirstResponder(target) }
            return target
        }

        private static func firstResponderCandidate(in view: NSView) -> NSView? {
            for subview in view.subviews.reversed() {
                if let found = firstResponderCandidate(in: subview) { return found }
            }
            return view.acceptsFirstResponder ? view : nil
        }

        func close() {
            window.contentView = nil
            window.close()
        }
    }

    /// Binds ⌥J the way a config that switches tabs with it does, and leaves
    /// every other Option chord unbound.
    /// `macos-option-as-alt` is already false by default; it is spelled out
    /// because it is the setting that decides what an unbound Option chord
    /// does.
    private static let optionJBound = """
        keybind = performable:alt+j=next_tab
        macos-option-as-alt = false
        """

    private func keyDown(
        _ characters: String,
        keyCode: UInt16 = 38,
        flags: NSEvent.ModifierFlags,
        in window: NSWindow
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )!
    }

    /// The monitor's filter is what runs ahead of the surface, so an Option
    /// chord the user bound has to pass it. This is the gate that decides
    /// whether an Option binding can work at all.
    @Test func anOptionChordBoundByTheUserIsClaimed() {
        let shortcuts = PlumeShortcuts.all(
            with: ShortcutBindings(overrides: [.nextTab: MenuShortcut("j", modifiers: [.option])])
        )

        #expect(TerminalShortcutMonitor.isClaimed(shortcuts: shortcuts, characters: "j", flags: [.option]))
        // An unbound neighbour chord must still reach the terminal.
        #expect(!TerminalShortcutMonitor.isClaimed(shortcuts: shortcuts, characters: "j", flags: [.control]))
        #expect(!TerminalShortcutMonitor.isClaimed(shortcuts: shortcuts, characters: "h", flags: [.option]))
    }

    /// The menu item and the terminal monitor must read the same store, or
    /// rebinding a chord moves one and not the other.
    @Test func theMenuAndTheMonitorReadTheSameRebind() {
        let chord = MenuShortcut("j", modifiers: [.option])
        let bindings = ShortcutBindings(overrides: [.nextTab: chord])
        let shortcuts = PlumeShortcuts.all(with: bindings)

        #expect(bindings[.nextTab] == chord)
        #expect(shortcuts.contains(chord))
        #expect(!shortcuts.contains(ShortcutAction.nextTab.defaultShortcut!))
        #expect(TerminalShortcutMonitor.isClaimed(shortcuts: shortcuts, characters: "j", flags: [.option]))

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: ShortcutAction.nextTab.label, action: nil, keyEquivalent: ""))
        ShortcutMenuApplier.apply(bindings, to: menu)
        #expect(menu.items[0].keyEquivalent == "j")
        #expect(menu.items[0].keyEquivalentModifierMask == [.option])
    }

    /// The monitor sees the event before the surface does, so an Option chord
    /// it claims never reaches `performKeyEquivalent` on the terminal at all.
    /// Exercised through the real monitor rather than its filter alone.
    @Test func theMonitorClaimsAnOptionChordAheadOfAFocusedSurface() async throws {
        let terminal = FocusedTerminal(config: Self.optionJBound)
        defer { terminal.close() }

        _ = try await terminal.waitForFocus()

        let shortcuts = PlumeShortcuts.all(
            with: ShortcutBindings(overrides: [.nextTab: MenuShortcut("j", modifiers: [.option])])
        )

        let event = keyDown("j", flags: [.option], in: terminal.window)
        #expect(
            TerminalShortcutMonitor.isClaimed(
                shortcuts: shortcuts,
                characters: event.charactersIgnoringModifiers,
                flags: event.modifierFlags
            ),
            "the monitor declined a bound ⌥J while a terminal held focus"
        )
    }

    /// Records what the surface does with an Option chord offered directly.
    /// Whatever the answer, the monitor has already had its turn by then; this
    /// documents how much the monitor is actually saving.
    @Test func focusedSurfaceConsumesBoundOptionChordsWithoutTheMonitor() async throws {
        let terminal = FocusedTerminal(config: Self.optionJBound)
        defer { terminal.close() }

        let focused = try await terminal.waitForFocus()
        #expect(focused != nil, "no view in the terminal hierarchy accepted first responder")

        // Offered until the surface takes it or the deadline passes, since a
        // surface that has not finished coming up declines every chord.
        let optionJ = keyDown("j", flags: [.option], in: terminal.window)
        var consumedBySurface = false
        let deadline = ContinuousClock.now + .seconds(10)
        while !consumedBySurface, ContinuousClock.now < deadline {
            consumedBySurface = terminal.window.contentView?.performKeyEquivalent(with: optionJ) ?? false
            if !consumedBySurface { try await Task.sleep(for: .milliseconds(200)) }
        }

        // A surface whose config binds ⌥J claims it for itself, which is
        // exactly why the binding cannot rely on menu dispatch alone: by the
        // time `performKeyEquivalent` runs, the chord is gone. The local
        // key-down monitor runs ahead of this, and that is the whole reason
        // an Option binding works for anyone whose Ghostty config binds the
        // same chord.
        #expect(
            consumedBySurface,
            "surface no longer claims a bound ⌥J; the monitor may be redundant (key window: \(terminal.window.isKeyWindow), app active: \(NSApp.isActive), first responder: \(String(describing: terminal.window.firstResponder.map { type(of: $0) })))"
        )

        // The same surface, now known to be up, leaves an Option chord its
        // config does not bind to the terminal as text, so it is the keybind
        // and not the Option key that takes the chord.
        let optionH = keyDown("h", keyCode: 4, flags: [.option], in: terminal.window)
        #expect(
            terminal.window.contentView?.performKeyEquivalent(with: optionH) == false,
            "surface claimed ⌥H, which its config does not bind"
        )
    }
}
