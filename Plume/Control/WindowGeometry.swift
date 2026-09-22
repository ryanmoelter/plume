#if DEBUG
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
}
#endif
