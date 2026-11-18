import CoreGraphics
import Foundation

/// Where the minimap draws the marks that aren't plain prompt bars.
enum MinimapMarks {
    static let endStrokeWidth: CGFloat = 0.75

    /// The path the end mark strokes, given the bar a prompt would fill in
    /// its place. The outline spans the bar's length and encloses its full
    /// thickness, so the end reads as a prompt not yet sent.
    static func endOutline(barRect: CGRect) -> CGRect {
        barRect.insetBy(dx: endStrokeWidth / 2, dy: -endStrokeWidth / 2)
    }
}
