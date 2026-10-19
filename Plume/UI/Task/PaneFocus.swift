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

    /// True while a click on the pane focused it and left first responder
    /// where the click put it, which may be selectable chat text that a
    /// claim would pull focus out of mid-selection.
    @Entry var paneFocusedByClick = false
}

private struct ClaimsPaneFocus: ViewModifier {
    let isFocused: Bool
    let claim: () -> Void
    @Environment(\.paneFocusedByClick) private var focusedByClick

    func body(content: Content) -> some View {
        content.onChange(of: isFocused && !focusedByClick, initial: true) { _, claims in
            // Deferred a tick: switching tasks replaces this whole subtree,
            // so the outgoing tab's view is still resigning real first
            // responder when the change fires. Claiming in the same
            // transaction loses that race silently.
            if claims { DispatchQueue.main.async(execute: claim) }
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

    /// Runs `claim` when this pane becomes focused, unless
    /// `paneFocusedByClick` says a click already placed first responder.
    func claimsPaneFocus(isFocused: Bool, claim: @escaping () -> Void) -> some View {
        modifier(ClaimsPaneFocus(isFocused: isFocused, claim: claim))
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
    /// Runs once the click has been dispatched, when it left first
    /// responder outside the pane, so the pane should claim it after all.
    let missed: () -> Void

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: ProbeView, context: Context) {
        view.gripXRange = gripXRange
        view.focus = focus
        view.missed = missed
    }

    static func dismantleNSView(_ view: ProbeView, coordinator: ()) {
        view.stopMonitoring()
    }

    final class ProbeView: NSView {
        var gripXRange: ClosedRange<CGFloat>?
        var focus: (() -> Void)?
        var missed: (() -> Void)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { stopMonitoring() } else { startMonitoring() }
        }

        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private func startMonitoring() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                self?.handle(event)
                return event
            }
        }

        private func handle(_ event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            guard let window, event.window === window, bounds.contains(point),
                  gripXRange?.contains(point.x) != true
            else { return }
            focus?()
            // Captured now: focusing the pane removes this probe. Checked
            // after the click has been dispatched, and so has set whatever
            // first responder it is going to.
            let paneFrame = convert(bounds, to: nil)
            let missed = missed
            DispatchQueue.main.async { [weak window] in
                guard let window, !Self.firstResponder(of: window, isWithin: paneFrame) else { return }
                missed?()
            }
        }

        private static func firstResponder(of window: NSWindow, isWithin paneFrame: CGRect) -> Bool {
            guard let responder = window.firstResponder as? NSView, responder.window === window else { return false }
            // `visibleRect`: a long message's text view runs far past its pane.
            let frame = responder.convert(responder.visibleRect, to: nil)
            return paneFrame.contains(CGPoint(x: frame.midX, y: frame.midY))
        }
    }
}
