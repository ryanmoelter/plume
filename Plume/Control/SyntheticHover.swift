#if DEBUG
import AppKit

/// Moves the synthetic pointer without clicking. SwiftUI's hover tracking
/// ignores every synthetic event — posted, sent to the window, or delivered
/// straight to the tracking area's owner — and a posted `mouseMoved` even
/// makes it un-hover what `HoverRegistry` just hovered. So no event is
/// posted; hover reaches views only through the regions `plumeHover`
/// registers, and the overlay cursor shows where the pointer is.
@MainActor
enum SyntheticHover {
    /// `point` is in the window's AppKit coordinates.
    static func move(to point: NSPoint, in window: NSWindow) {
        ControlOverlay.overlay(for: window).moveCursor(to: point)
        let height = window.contentView?.bounds.height ?? window.frame.height
        HoverRegistry.shared.pointerMoved(to: WindowGeometry.topLeftPoint(fromAppKit: point, contentHeight: height), in: window)
    }

    /// Moves the pointer off the window so hover states settle back.
    static func leave(_ window: NSWindow) {
        HoverRegistry.shared.pointerLeft(window)
    }
}
#endif
