#if DEBUG
import AppKit

/// Runs a resize the way dragging a window's edge does, so `inLiveResize`
/// reads true throughout and every view hears `viewWillStartLiveResize`
/// before it and `viewDidEndLiveResize` after.
///
/// AppKit starts a live resize only from the window server's drag, so this
/// calls the private `_startLiveResize` and `_endLiveResize` that drag
/// calls. Debug only, and refused rather than faked when either is missing.
@MainActor
enum WindowLiveResize {
    private static let start = NSSelectorFromString("_startLiveResize")
    private static let end = NSSelectorFromString("_endLiveResize")

    static var isAvailable: Bool {
        NSWindow.instancesRespond(to: start) && NSWindow.instancesRespond(to: end)
    }

    static func run(_ window: NSWindow, resizing: () async throws -> Void) async throws {
        guard isAvailable else { throw ControlError.unsupported("this macOS has no NSWindow live-resize entry points") }
        window.perform(start)
        defer { window.perform(end) }
        try await resizing()
    }
}
#endif
