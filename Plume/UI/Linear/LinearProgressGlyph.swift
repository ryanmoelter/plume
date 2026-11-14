import AppKit
import SwiftUI

nonisolated enum LinearProgressGlyphWeight: Hashable, Sendable {
    case regular
    case bold

    /// Measured from SF Symbols' `circle` at this weight, per point of font
    /// size: its ring's stroke, the ring's outer diameter, and the square
    /// image the symbol draws in.
    fileprivate var strokeRatio: CGFloat {
        switch self {
        case .regular: 0.083
        case .bold: 0.134
        }
    }

    fileprivate var diameterRatio: CGFloat {
        switch self {
        case .regular: 1.0
        case .bold: 1.07
        }
    }

    fileprivate var boxRatio: CGFloat {
        switch self {
        case .regular: 1.17
        case .bold: 1.24
        }
    }

    var fontWeight: Font.Weight {
        switch self {
        case .regular: .regular
        case .bold: .bold
        }
    }
}

/// Linear's started-state mark: a ring around a pie that fills clockwise
/// from 12 o'clock, with a gap as wide as the ring between them. Sized so it
/// sits beside SF Symbols' `circle` at the same font size and weight with
/// the same ring.
nonisolated struct LinearProgressGlyphMetrics: Equatable {
    let pointSize: CGFloat
    let weight: LinearProgressGlyphWeight

    init(pointSize: CGFloat, weight: LinearProgressGlyphWeight = .regular) {
        self.pointSize = pointSize
        self.weight = weight
    }

    /// For a surface that knows only the square a `circle` symbol fills.
    init(boxSide: CGFloat, weight: LinearProgressGlyphWeight = .regular) {
        self.init(pointSize: boxSide / weight.boxRatio, weight: weight)
    }

    var strokeWidth: CGFloat { pointSize * weight.strokeRatio }
    var diameter: CGFloat { pointSize * weight.diameterRatio }
    var boxSide: CGFloat { pointSize * weight.boxRatio }
    var wedgeRadius: CGFloat { max(0, diameter / 2 - 2 * strokeWidth) }

    static func wedgeAngles(for progress: LinearStartedProgress) -> (start: Angle, sweep: Angle) {
        let fraction: Double = switch progress {
        case .quarter: 0.25
        case .half: 0.5
        case .threeQuarters: 0.75
        }
        return (.degrees(-90), .degrees(360 * fraction))
    }

    /// One path to fill, centered in `rect`, in y-down coordinates.
    func path(progress: LinearStartedProgress, in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let ringRadius = (diameter - strokeWidth) / 2
        var path = Path(ellipseIn: CGRect(
            x: center.x - ringRadius, y: center.y - ringRadius, width: 2 * ringRadius, height: 2 * ringRadius
        )).strokedPath(StrokeStyle(lineWidth: strokeWidth))
        path.addPath(wedge(progress: progress, center: center))
        return path
    }

    func wedge(progress: LinearStartedProgress, center: CGPoint) -> Path {
        let angles = Self.wedgeAngles(for: progress)
        var wedge = Path()
        wedge.move(to: center)
        // Clockwise on screen: SwiftUI's y axis points down.
        wedge.addArc(
            center: center,
            radius: wedgeRadius,
            startAngle: angles.start,
            endAngle: angles.start + angles.sweep,
            clockwise: false
        )
        wedge.closeSubpath()
        return wedge
    }
}

/// Fills whatever frame it gets as the square a `circle` symbol fills.
nonisolated struct LinearProgressGlyphShape: Shape {
    let progress: LinearStartedProgress
    var weight: LinearProgressGlyphWeight = .regular

    func path(in rect: CGRect) -> Path {
        LinearProgressGlyphMetrics(boxSide: min(rect.width, rect.height), weight: weight)
            .path(progress: progress, in: rect)
    }
}

/// Laid out as a `circle` symbol in the current font would be, baseline
/// included, and filled with the foreground style.
struct LinearProgressGlyph: View {
    let progress: LinearStartedProgress
    var weight: LinearProgressGlyphWeight = .regular

    var body: some View {
        Image(systemName: "circle")
            .fontWeight(weight.fontWeight)
            .hidden()
            .overlay(LinearProgressGlyphShape(progress: progress, weight: weight))
    }

    /// For a surface that draws an image rather than a view.
    static func image(
        progress: LinearStartedProgress,
        side: CGFloat,
        weight: LinearProgressGlyphWeight = .regular,
        color: NSColor
    ) -> NSImage {
        let metrics = LinearProgressGlyphMetrics(boxSide: side, weight: weight)
        return NSImage(size: NSSize(width: side, height: side), flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.addPath(metrics.path(progress: progress, in: rect).cgPath)
            context.setFillColor(color.cgColor)
            context.fillPath()
            return true
        }
    }
}
