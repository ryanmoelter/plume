import CoreGraphics
import Foundation

/// Where the minimap draws the marks that aren't plain prompt bars.
enum MinimapMarks {
    /// An indirect prompt's mark, as thick as a prompt bar. `promptLength`
    /// is the bar a typed prompt would draw on the same row.
    static func indirectSize(shape: MinimapIndirectShape, promptLength: CGFloat, thickness: CGFloat) -> CGSize {
        switch shape {
        case .dot: CGSize(width: thickness, height: thickness)
        case .line: CGSize(width: promptLength / 4, height: thickness)
        }
    }

    /// The end stands for the composer, which is always on screen, so it
    /// never dims with the rows scrolled out of view.
    static func opacity(isHovered: Bool, isEnd: Bool, isVisible: Bool) -> Double {
        if isHovered || isEnd { return 1 }
        return isVisible ? 0.85 : 0.35
    }

    static let endStrokeWidth: CGFloat = 0.75

    /// The path the end mark strokes, given the bar a prompt would fill in
    /// its place. The outline spans the bar's length and encloses its full
    /// thickness, so the end reads as a prompt not yet sent.
    static func endOutline(barRect: CGRect) -> CGRect {
        barRect.insetBy(dx: endStrokeWidth / 2, dy: -endStrokeWidth / 2)
    }
}
