#if DEBUG
import AppKit

/// Posts a left click into a window from inside the process, without
/// activating the app or moving the pointer.
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
        window.makeKey()
        NSApp.postEvent(down, atStart: false)
        try? await Task.sleep(for: releaseDelay)
        NSApp.postEvent(up, atStart: false)
        await Task.yield()
    }
}
#endif
