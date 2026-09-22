#if DEBUG
import AppKit
import CoreGraphics
import Foundation

/// The control server speaks top-left content-view coordinates, the space
/// SwiftUI's `.global` frames and a screenshot's pixels share. AppKit's
/// bottom-left window space is converted here and nowhere else.
enum WindowGeometry {
    static func appKitRect(fromTopLeft rect: CGRect, contentHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: contentHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    static func topLeftRect(fromAppKit rect: CGRect, contentHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: contentHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    static func appKitPoint(fromTopLeft point: CGPoint, contentHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: contentHeight - point.y)
    }

    static func topLeftPoint(fromAppKit point: CGPoint, contentHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: contentHeight - point.y)
    }

    /// SwiftUI's `.global` space hangs from the top-left of the window
    /// *frame*, title bar included, where every rect here hangs from the
    /// content view's own top-left. The two agree only when the content view
    /// fills the frame. Measured in `ControlHierarchyTests`.
    static func contentRect(fromGlobal rect: CGRect, in window: NSWindow?) -> CGRect {
        guard let window, let content = window.contentView else { return rect }
        let contentInWindow = content.convert(content.bounds, to: nil)
        let titleInset = window.frame.height - contentInWindow.maxY
        return rect.offsetBy(dx: -contentInWindow.minX, dy: -titleInset)
    }
}
#endif
