import CoreGraphics
import Testing
@testable import Plume

struct WheelAccumulatorTests {
    @Test func nonPreciseLineIsOneNotch() {
        var wheel = WheelAccumulator()
        let out = wheel.add(deltaX: 0, deltaY: 1, hasPreciseDeltas: false)
        #expect(out.dx == 0)
        #expect(out.dy == 120)
    }

    @Test func nonPreciseKeepsSign() {
        var wheel = WheelAccumulator()
        let out = wheel.add(deltaX: -2, deltaY: -1, hasPreciseDeltas: false)
        #expect(out.dx == -240)
        #expect(out.dy == -120)
    }

    @Test func preciseDeltasAccumulateUntilANotch() {
        var wheel = WheelAccumulator()
        #expect(wheel.add(deltaX: 0, deltaY: 15, hasPreciseDeltas: true).dy == 0)
        #expect(wheel.add(deltaX: 0, deltaY: 15, hasPreciseDeltas: true).dy == 0)
        #expect(wheel.add(deltaX: 0, deltaY: 15, hasPreciseDeltas: true).dy == 120)
    }

    @Test func preciseRemainderCarries() {
        var wheel = WheelAccumulator()
        #expect(wheel.add(deltaX: 0, deltaY: 100, hasPreciseDeltas: true).dy == 240)
        // 20 points carried over; 20 more completes a notch
        #expect(wheel.add(deltaX: 0, deltaY: 20, hasPreciseDeltas: true).dy == 120)
    }

    @Test func preciseNegativeDeltasKeepSignAndCarry() {
        var wheel = WheelAccumulator()
        #expect(wheel.add(deltaX: 0, deltaY: -30, hasPreciseDeltas: true).dy == 0)
        #expect(wheel.add(deltaX: 0, deltaY: -30, hasPreciseDeltas: true).dy == -120)
        #expect(wheel.add(deltaX: 0, deltaY: -20, hasPreciseDeltas: true).dy == -120)
    }

    @Test func axesAccumulateIndependently() {
        var wheel = WheelAccumulator()
        let out = wheel.add(deltaX: 45, deltaY: 10, hasPreciseDeltas: true)
        #expect(out.dx == 120)
        #expect(out.dy == 0)
    }

    @Test func resetDropsRemainder() {
        var wheel = WheelAccumulator()
        _ = wheel.add(deltaX: 30, deltaY: 30, hasPreciseDeltas: true)
        wheel.reset()
        let out = wheel.add(deltaX: 15, deltaY: 15, hasPreciseDeltas: true)
        #expect(out.dx == 0)
        #expect(out.dy == 0)
    }
}
