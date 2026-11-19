#if DEBUG
import AppKit

/// Posts a left click into a window from inside the process, without
/// activating the app or moving the pointer. The overlay cursor moves there
/// first and a ring marks the click.
@MainActor
enum SyntheticClick {
    /// With the up queued right behind the down, AppKit's tracking loop exits
    /// before it pumps the run loop, which a human click always lets it do.
    static let releaseDelay: Duration = .milliseconds(150)

    static let dragStepDelay: Duration = .milliseconds(30)

    /// What happens after the mouse-down, each after its delay.
    struct FollowUp {
        let delay: Duration
        let action: @MainActor () -> Void
    }

    /// `point` is in the window's AppKit coordinates. The window is made key
    /// (not activated) first, so a first mouse-down is not swallowed.
    static func perform(at point: NSPoint, in window: NSWindow, clickCount: Int = 1) async {
        guard let down = event(.leftMouseDown, at: point, in: window, clickCount: clickCount),
              let up = event(.leftMouseUp, at: point, in: window, clickCount: clickCount)
        else { return }
        SyntheticHover.move(to: point, in: window)
        ControlOverlay.overlay(for: window).flashClick(at: point)
        window.makeKey()
        await deliver(down, at: point, in: window, then: [FollowUp(delay: releaseDelay) { NSApp.postEvent(up, atStart: false) }])
    }

    /// Down at `start`, `steps` drag events along the line, up at `end`.
    static func drag(from start: NSPoint, to end: NSPoint, in window: NSWindow, clickCount: Int = 1, steps: Int = 10) async {
        guard let down = event(.leftMouseDown, at: start, in: window, clickCount: clickCount) else { return }
        SyntheticHover.move(to: start, in: window)
        ControlOverlay.overlay(for: window).flashClick(at: start)
        window.makeKey()
        let count = max(steps, 1)
        var followUps: [FollowUp] = []
        for step in 1...count {
            let fraction = CGFloat(step) / CGFloat(count)
            let point = NSPoint(x: start.x + (end.x - start.x) * fraction, y: start.y + (end.y - start.y) * fraction)
            let dragged = event(.leftMouseDragged, at: point, in: window, clickCount: clickCount)
            followUps.append(FollowUp(delay: step == 1 ? releaseDelay : dragStepDelay) {
                SyntheticHover.move(to: point, in: window)
                if let dragged { NSApp.postEvent(dragged, atStart: false) }
            })
        }
        let up = event(.leftMouseUp, at: end, in: window, clickCount: clickCount)
        followUps.append(FollowUp(delay: dragStepDelay) { if let up { NSApp.postEvent(up, atStart: false) } })
        await deliver(down, at: start, in: window, then: followUps)
    }

    /// The view `NSWindow` sends a mouse-down at `point` to. `point` is in
    /// the window's AppKit coordinates, which are the frame view's own.
    static func hitView(at point: NSPoint, in window: NSWindow) -> NSView? {
        guard let content = window.contentView else { return nil }
        let root = content.superview ?? content
        return root.hitTest(root.superview.map { $0.convert(point, from: nil) } ?? point)
    }

    /// The view a mouse-down at `point` must be handed to directly, or nil
    /// when posting it reaches the view.
    ///
    /// A driven instance is never active, so its window is never key, and
    /// `NSWindow` spends the first click on a non-key window making it key
    /// unless the view under it accepts first mouse. `NSTextView` does not,
    /// so a posted click never reaches the composer at all.
    static func viewRefusingFirstMouse(at point: NSPoint, in window: NSWindow, for down: NSEvent) -> NSView? {
        guard !window.isKeyWindow, let view = hitView(at: point, in: window), !view.acceptsFirstMouse(for: down) else { return nil }
        return view
    }

    private static func deliver(_ down: NSEvent, at point: NSPoint, in window: NSWindow, then followUps: [FollowUp]) async {
        let total = followUps.reduce(Duration.zero) { $0 + $1.delay }
        if let view = viewRefusingFirstMouse(at: point, in: window, for: down) {
            // The view's tracking loop runs the run loop in event-tracking
            // mode until the mouse-up, so the follow-ups ride timers in the
            // common modes; a sleeping task would never resume to post them.
            let runner = FollowUpRunner(followUps)
            runner.schedule()
            let start = ContinuousClock.now
            if view.acceptsFirstResponder, window.firstResponder !== view { window.makeFirstResponder(view) }
            view.mouseDown(with: down)
            let remaining = total - (ContinuousClock.now - start)
            if remaining > .zero { try? await Task.sleep(for: remaining) }
            runner.flush()
        } else {
            NSApp.postEvent(down, atStart: false)
            for followUp in followUps {
                try? await Task.sleep(for: followUp.delay)
                followUp.action()
            }
        }
        await Task.yield()
    }

    private static func event(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow, clickCount: Int) -> NSEvent? {
        NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 4242, clickCount: clickCount, pressure: type == .leftMouseUp ? 0 : 1
        )
    }
}

/// Runs follow-ups from timers in the common run-loop modes, in order.
@MainActor
private final class FollowUpRunner: NSObject {
    private var pending: [SyntheticClick.FollowUp]
    private var timers: [Timer] = []

    init(_ followUps: [SyntheticClick.FollowUp]) {
        pending = followUps
    }

    func schedule() {
        var elapsed = Duration.zero
        for followUp in pending {
            elapsed += followUp.delay
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            let timer = Timer(timeInterval: seconds, target: self, selector: #selector(fire), userInfo: nil, repeats: false)
            RunLoop.main.add(timer, forMode: .common)
            timers.append(timer)
        }
    }

    @objc private func fire() {
        guard !pending.isEmpty else { return }
        pending.removeFirst().action()
    }

    /// Runs whatever has not fired yet, so the mouse-up is never lost.
    func flush() {
        timers.forEach { $0.invalidate() }
        while !pending.isEmpty { pending.removeFirst().action() }
    }
}
#endif
