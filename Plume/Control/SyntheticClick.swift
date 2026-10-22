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

    /// `point` is in the window's AppKit coordinates. The window is made key
    /// (not activated) first, so a first mouse-down is not swallowed.
    static func perform(at point: NSPoint, in window: NSWindow, clickCount: Int = 1) async {
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 4242, clickCount: clickCount, pressure: type == .leftMouseDown ? 1 : 0
            )
        }
        guard let down = event(.leftMouseDown), let up = event(.leftMouseUp) else { return }
        SyntheticHover.move(to: point, in: window)
        ControlOverlay.overlay(for: window).flashClick(at: point)
        window.makeKey()
        NSApp.postEvent(down, atStart: false)
        try? await Task.sleep(for: releaseDelay)
        NSApp.postEvent(up, atStart: false)
        await Task.yield()
    }

    static let dragStepDelay: Duration = .milliseconds(30)

    /// Down at `start`, `steps` drag events along the line, up at `end`.
    static func drag(from start: NSPoint, to end: NSPoint, in window: NSWindow, clickCount: Int = 1, steps: Int = 10) async {
        func event(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent? {
            NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 4242, clickCount: clickCount, pressure: type == .leftMouseUp ? 0 : 1
            )
        }
        let overlay = ControlOverlay.overlay(for: window)
        SyntheticHover.move(to: start, in: window)
        overlay.flashClick(at: start)
        window.makeKey()
        guard let down = event(.leftMouseDown, at: start) else { return }
        NSApp.postEvent(down, atStart: false)
        try? await Task.sleep(for: releaseDelay)
        let count = max(steps, 1)
        for step in 1...count {
            let fraction = CGFloat(step) / CGFloat(count)
            let point = NSPoint(x: start.x + (end.x - start.x) * fraction, y: start.y + (end.y - start.y) * fraction)
            SyntheticHover.move(to: point, in: window)
            if let dragged = event(.leftMouseDragged, at: point) { NSApp.postEvent(dragged, atStart: false) }
            try? await Task.sleep(for: dragStepDelay)
        }
        if let up = event(.leftMouseUp, at: end) { NSApp.postEvent(up, atStart: false) }
        await Task.yield()
    }
}
#endif
