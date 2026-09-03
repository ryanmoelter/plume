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
}
