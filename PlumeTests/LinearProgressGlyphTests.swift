import AppKit
import SwiftUI
import Testing

@testable import Plume

/// The started-state pie fills clockwise from 12 o'clock, and its ring keeps
/// SF Symbols' `circle` stroke at every size and weight.
struct LinearProgressGlyphTests {
    @Test(arguments: [
        (LinearStartedProgress.quarter, 90.0),
        (.half, 180.0),
        (.threeQuarters, 270.0),
    ])
    func theWedgeStartsAtTwelveAndSweepsItsFill(progress: LinearStartedProgress, sweep: Double) {
        let angles = LinearProgressGlyphMetrics.wedgeAngles(for: progress)
        #expect(angles.start.degrees == -90)
        #expect(angles.sweep.degrees == sweep)
    }

    @Test func theWedgeFillsClockwiseOnScreen() {
        let metrics = LinearProgressGlyphMetrics(pointSize: 100)
        let center = CGPoint(x: 0, y: 0)
        let radius = metrics.wedgeRadius

        let quarter = metrics.wedge(progress: .quarter, center: center).boundingRect
        #expect(abs(quarter.minX) < 0.01)
        #expect(abs(quarter.maxX - radius) < 0.01)
        #expect(abs(quarter.minY + radius) < 0.01)
        #expect(abs(quarter.maxY) < 0.01)

        let half = metrics.wedge(progress: .half, center: center).boundingRect
        #expect(abs(half.minX) < 0.01)
        #expect(abs(half.height - 2 * radius) < 0.01)

        let threeQuarters = metrics.wedge(progress: .threeQuarters, center: center).boundingRect
        #expect(abs(threeQuarters.minX + radius) < 0.01)
        #expect(abs(threeQuarters.minY + radius) < 0.01)
        #expect(abs(threeQuarters.maxY - radius) < 0.01)
    }

    @Test func theStrokeScalesWithTheFontSize() {
        let small = LinearProgressGlyphMetrics(pointSize: 11)
        let large = LinearProgressGlyphMetrics(pointSize: 22)
        #expect(abs(large.strokeWidth - 2 * small.strokeWidth) < 0.0001)
        #expect(abs(large.diameter - 2 * small.diameter) < 0.0001)
    }

    @Test func aBoldStrokeIsHeavier() {
        let regular = LinearProgressGlyphMetrics(pointSize: 13, weight: .regular)
        let bold = LinearProgressGlyphMetrics(pointSize: 13, weight: .bold)
        #expect(bold.strokeWidth > regular.strokeWidth)
        #expect(bold.diameter > regular.diameter)
    }

    /// SF Symbols' regular `circle` at 13 pt has a 13 pt ring stroked about
    /// 1.08 pt wide in a 15 pt image.
    @Test func theRegularGlyphMatchesTheCircleSymbol() {
        let metrics = LinearProgressGlyphMetrics(pointSize: 13)
        #expect(abs(metrics.strokeWidth - 1.08) < 0.05)
        #expect(abs(metrics.diameter - 13) < 0.25)
        #expect(abs(metrics.boxSide - 15) < 0.5)
    }

    @Test func aBoxSideRecoversThePointSize() {
        for weight in [LinearProgressGlyphWeight.regular, .bold] {
            let metrics = LinearProgressGlyphMetrics(pointSize: 13, weight: weight)
            #expect(abs(LinearProgressGlyphMetrics(boxSide: metrics.boxSide, weight: weight).pointSize - 13) < 0.0001)
        }
    }

    @Test func theWedgeLeavesAGapInsideTheRing() {
        let metrics = LinearProgressGlyphMetrics(pointSize: 13)
        let ringInnerRadius = metrics.diameter / 2 - metrics.strokeWidth
        #expect(metrics.wedgeRadius > 0)
        #expect(abs(ringInnerRadius - metrics.wedgeRadius - metrics.strokeWidth) < 0.0001)
    }
}
