import AppKit
import Dispatch
import SwiftUI

/// Whether the pane holding a view is the focused one. A reference rather than
/// a value so the chat list's hosted rows, which receive it once at staging,
/// still follow later changes.
@Observable
final class PaneFocusState {
    var isFocused = true
}

extension EnvironmentValues {
    /// Nil outside a pane, which reads as focused.
    @Entry var paneFocus: PaneFocusState?

    /// The pane holding a view, for asking whether first responder is
    /// already inside it. Nil outside a pane.
    @Entry var paneAnchor: PaneAnchor?
}

/// When a view that takes keyboard focus should claim it.
struct PaneFocusClaim: Equatable {
    var isVisible: Bool
    var isFocused: Bool

    var claims: Bool { isVisible && isFocused }

    /// Only an on-screen pane gaining focus can have been focused by a click
    /// inside it, which already put first responder where the user wants it —
    /// possibly selectable chat text, which a claim would pull focus out of
    /// mid-selection.
    static func defersToFirstResponder(from old: Self, to new: Self) -> Bool {
        new.claims && old.isVisible && !old.isFocused
    }
}

private struct ClaimsPaneFocus: ViewModifier {
    let state: PaneFocusClaim
    let claim: () -> Void
    @Environment(\.paneAnchor) private var paneAnchor

    func body(content: Content) -> some View {
        content.onChange(of: state, initial: true) { old, new in
            guard new.claims, old == new || !old.claims else { return }
            let defers = PaneFocusClaim.defersToFirstResponder(from: old, to: new)
            let anchor = paneAnchor
            // Deferred a tick: switching tasks replaces this whole subtree,
            // so the outgoing tab's view is still resigning real first
            // responder when the change fires. Claiming in the same
            // transaction loses that race silently. It also lets a click
            // that focused the pane place first responder before the check.
            DispatchQueue.main.async {
                if defers, anchor?.containsFirstResponder == true { return }
                claim()
            }
        }
    }
}

private struct PaneKeyboardShortcut: ViewModifier {
    let shortcut: KeyboardShortcut?
    @Environment(\.paneFocus) private var paneFocus

    func body(content: Content) -> some View {
        content.keyboardShortcut(paneFocus?.isFocused == false ? nil : shortcut)
    }
}

extension View {
    /// A keyboard shortcut that only the focused pane answers. Both panes of
    /// a split are in the window, so a bare `keyboardShortcut` would fire in
    /// the unfocused one too.
    func paneKeyboardShortcut(_ shortcut: KeyboardShortcut?) -> some View {
        modifier(PaneKeyboardShortcut(shortcut: shortcut))
    }

    /// Runs `claim` when this view becomes visible in the focused pane. An
    /// on-screen pane gaining focus claims only if first responder is not
    /// already inside it.
    func claimsPaneFocus(isVisible: Bool, isFocused: Bool, claim: @escaping () -> Void) -> some View {
        modifier(ClaimsPaneFocus(state: PaneFocusClaim(isVisible: isVisible, isFocused: isFocused), claim: claim))
    }

    /// Marks this view's frame as a pane, for `claimsPaneFocus` inside it.
    func paneAnchored() -> some View {
        modifier(PaneAnchoring())
    }
}

/// Focuses its pane when a click lands in it. A background behind the pane,
/// watching mouse-downs rather than taking them, so the click still reaches
/// the terminal or chat underneath.
struct PaneClickProbe: NSViewRepresentable {
    /// The divider's grip, in the pane's own x, which overhangs the pane. A
    /// click there starts a resize and must not focus the pane.
    var gripXRange: ClosedRange<CGFloat>?
    let focus: () -> Void

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: ProbeView, context: Context) {
        view.gripXRange = gripXRange
        view.focus = focus
    }

    static func dismantleNSView(_ view: ProbeView, coordinator: ()) {
        view.stopMonitoring()
    }

    /// Hands a mouse-down to every probe. A monitor that swallows one, as
    /// the chat's text selection does, must call this, because a swallowed
    /// event may never reach the probes' own monitors.
    static func observe(_ event: NSEvent) {
        for probe in ProbeView.live.allObjects { probe.handle(event) }
    }

    final class ProbeView: NSView {
        fileprivate static let live = NSHashTable<ProbeView>.weakObjects()
        var gripXRange: ClosedRange<CGFloat>?
        var focus: (() -> Void)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { stopMonitoring() } else { startMonitoring() }
        }

        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            Self.live.remove(self)
        }

        private func startMonitoring() {
            guard monitor == nil else { return }
            Self.live.add(self)
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                self?.handle(event)
                return event
            }
        }

        fileprivate func handle(_ event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            guard window != nil, event.window === window, bounds.contains(point),
                  gripXRange?.contains(point.x) != true
            else { return }
            focus?()
        }
    }
}

/// The NSView behind a pane, so a claim can check where first responder is.
@MainActor
final class PaneAnchor {
    fileprivate weak var view: NSView?

    var containsFirstResponder: Bool {
        guard let view, let window = view.window else { return false }
        return Self.firstResponder(of: window, isWithin: view.convert(view.bounds, to: nil))
    }

    static func firstResponder(of window: NSWindow, isWithin paneFrame: CGRect) -> Bool {
        guard let responder = window.firstResponder as? NSView, responder.window === window else { return false }
        let frame = responder.convert(responder.shownRect, to: nil)
        return paneFrame.contains(CGPoint(x: frame.midX, y: frame.midY))
    }
}

private struct PaneAnchoring: ViewModifier {
    @State private var anchor = PaneAnchor()

    func body(content: Content) -> some View {
        content
            .environment(\.paneAnchor, anchor)
            .background(PaneAnchorView(anchor: anchor).allowsHitTesting(false))
    }
}

private struct PaneAnchorView: NSViewRepresentable {
    let anchor: PaneAnchor

    func makeNSView(context: Context) -> NSView {
        let view = PassThroughView()
        anchor.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        anchor.view = view
    }

    private final class PassThroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

extension NSView {
    /// The part of the view on screen, in its own coordinates. A long
    /// message's text view runs far past its pane, so `visibleRect` narrows
    /// it — but with `clipsToBounds` off, `visibleRect` can also run past the
    /// view's own bounds, so it is held to them.
    var shownRect: CGRect {
        let shown = visibleRect.intersection(bounds)
        return shown.isEmpty ? bounds : shown
    }
}
