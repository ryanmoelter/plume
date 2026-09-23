import Foundation
import Testing
@testable import Plume

struct StatuslineMeterMathTests {
    @Test func fractionScalesPercentTo0To1() {
        #expect(StatuslineMeterMath.fraction(percent: 0) == 0)
        #expect(StatuslineMeterMath.fraction(percent: 50) == 0.5)
        #expect(StatuslineMeterMath.fraction(percent: 100) == 1)
    }

    @Test func fractionClampsOutOfRangePercent() {
        #expect(StatuslineMeterMath.fraction(percent: -10) == 0)
        #expect(StatuslineMeterMath.fraction(percent: 150) == 1)
    }

    @Test func fractionTreatsNilAsZero() {
        #expect(StatuslineMeterMath.fraction(percent: nil) == 0)
    }

    @Test func fillWidthNeverExceedsTrackWidth() {
        for trackWidth: CGFloat in [0, 1, 3.5, 12, 28, 100] {
            for fraction in [0, 0.001, 0.5, 0.999, 1, 1.5] {
                let fillWidth = StatuslineMeterMath.fillWidth(trackWidth: trackWidth, fraction: fraction)
                #expect(fillWidth <= trackWidth)
                #expect(fillWidth >= 0)
            }
        }
    }

    @Test func fillWidthScalesLinearly() {
        #expect(StatuslineMeterMath.fillWidth(trackWidth: 40, fraction: 0.5) == 20)
        #expect(StatuslineMeterMath.fillWidth(trackWidth: 40, fraction: 1) == 40)
        #expect(StatuslineMeterMath.fillWidth(trackWidth: 40, fraction: 0) == 0)
    }
}
