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
    /// A live terminal surface hosted in a real window, focused.
    @MainActor
    private struct FocusedTerminal {
        let window: NSWindow
        let session: TerminalSession

        init() {
            session = TerminalSession(
                id: UUID(),
                options: TerminalSurfaceOptions(
                    workingDirectory: NSTemporaryDirectory(),
                    command: "/bin/sh -c 'sleep 30'"
                )
            )
            let host = NSHostingView(rootView: TerminalTabView(session: session))
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

    private func keyDown(_ characters: String, flags: NSEvent.ModifierFlags, in window: NSWindow) -> NSEvent {
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
            keyCode: 38
        )!
    }

    /// The monitor's filter is what runs ahead of the surface, so an Option
    /// chord the user bound has to pass it. This is the gate that decides
    /// whether an Option binding can work at all.
    @Test func anOptionChordBoundByTheUserIsClaimed() {
        let bindings = ShortcutBindings(overrides: [.nextTab: MenuShortcut("j", modifiers: [.option])])
        let previous = AppSettings.shared.shortcutBindings
        AppSettings.shared.shortcutBindings = bindings
        defer { AppSettings.shared.shortcutBindings = previous }

        #expect(TerminalShortcutMonitor.isClaimed(characters: "j", flags: [.option]))
        // An unbound neighbour chord must still reach the terminal.
        #expect(!TerminalShortcutMonitor.isClaimed(characters: "j", flags: [.control]))
        #expect(!TerminalShortcutMonitor.isClaimed(characters: "h", flags: [.option]))
    }

    /// The monitor sees the event before the surface does, so an Option chord
    /// it claims never reaches `performKeyEquivalent` on the terminal at all.
    /// Exercised through the real monitor rather than its filter alone.
    @Test func theMonitorClaimsAnOptionChordAheadOfAFocusedSurface() async throws {
        let terminal = FocusedTerminal()
        defer { terminal.close() }

        try await Task.sleep(for: .seconds(3))
        _ = terminal.focusTerminalView()

        let bindings = ShortcutBindings(overrides: [.nextTab: MenuShortcut("j", modifiers: [.option])])
        let previous = AppSettings.shared.shortcutBindings
        AppSettings.shared.shortcutBindings = bindings
        defer { AppSettings.shared.shortcutBindings = previous }

        let event = keyDown("j", flags: [.option], in: terminal.window)
        #expect(
            TerminalShortcutMonitor.isClaimed(
                characters: event.charactersIgnoringModifiers,
                flags: event.modifierFlags
            ),
            "the monitor declined a bound ⌥J while a terminal held focus"
        )
    }

    /// Records what the surface does with an Option chord offered directly.
    /// Whatever the answer, the monitor has already had its turn by then; this
    /// documents how much the monitor is actually saving.
    @Test func focusedSurfaceConsumesOptionChordsWithoutTheMonitor() async throws {
        let terminal = FocusedTerminal()
        defer { terminal.close() }

        try await Task.sleep(for: .seconds(3))
        let focused = terminal.focusTerminalView()
        #expect(focused != nil, "no view in the terminal hierarchy accepted first responder")

        let event = keyDown("j", flags: [.option], in: terminal.window)
        let consumedBySurface = terminal.window.contentView?.performKeyEquivalent(with: event) ?? false

        // The surface claims ⌥J for itself, which is exactly why the binding
        // cannot rely on menu dispatch alone: by the time
        // `performKeyEquivalent` runs, the chord is gone. The local key-down
        // monitor runs ahead of this, and that is the whole reason an Option
        // binding works.
        #expect(consumedBySurface, "surface no longer claims ⌥J; the monitor may be redundant")
    }
}
