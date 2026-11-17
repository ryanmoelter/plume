import Foundation
import Testing
@testable import Plume

/// The minimap's pickup scrolling: hovering never jumps the map, and the
/// scroll then catches up with the pointer's absolute position from either
/// direction before moving with it one to one.
@MainActor
struct MinimapCatchUpTests {
    @Test func enteringKeepsTheScrollWhereItWas() {
        let catchUp = MinimapCatchUp(scroll: 0.8, pointer: 0.2, gain: 4)
        #expect(catchUp.scroll == 0.8)
        #expect(!catchUp.isLocked)
    }

    @Test func atTheBottomMovingDownDoesNothing() {
        var catchUp = MinimapCatchUp(scroll: 1, pointer: 0.5, gain: 4)
        catchUp.move(to: 0.6)
        catchUp.move(to: 0.7)
        #expect(catchUp.scroll == 1)
    }

    @Test func atTheTopMovingUpDoesNothing() {
        var catchUp = MinimapCatchUp(scroll: 0, pointer: 0.5, gain: 4)
        catchUp.move(to: 0.4)
        #expect(catchUp.scroll == 0)
    }

    @Test func movingTowardTheGapScrollsFasterThenLocks() {
        var catchUp = MinimapCatchUp(scroll: 0.2, pointer: 0.6, gain: 10)
        catchUp.move(to: 0.65)
        // 0.05 × (1 + 10 × 0.4).
        #expect(abs(catchUp.scroll - (0.2 + 0.05 * 5)) < 0.0001)
        for step in 1...60 where !catchUp.isLocked {
            catchUp.move(to: 0.65 + CGFloat(step) * 0.005)
        }
        #expect(catchUp.isLocked)
        let pointer = catchUp.pointer
        catchUp.move(to: pointer + 0.01)
        #expect(abs(catchUp.scroll - catchUp.pointer) < 0.0001)
    }

    @Test func movingAwayFromTheGapScrollsSlower() {
        var catchUp = MinimapCatchUp(scroll: 0.2, pointer: 0.6, gain: 4)
        catchUp.move(to: 0.55)
        // Up 0.05 / (1 + 4 × 0.4).
        #expect(abs(catchUp.scroll - (0.2 - 0.05 / 2.6)) < 0.0001)
        #expect(catchUp.scroll > 0.2 - 0.05)
    }

    @Test func theGainShrinksAsTheGapCloses() {
        var far = MinimapCatchUp(scroll: 0, pointer: 0.8, gain: 4)
        var near = MinimapCatchUp(scroll: 0.7, pointer: 0.8, gain: 4)
        far.move(to: 0.81)
        near.move(to: 0.81)
        #expect(far.scroll - 0 > near.scroll - 0.7)
        #expect(near.scroll - 0.7 > 0.01)
    }

    @Test func eitherDirectionConverges() {
        for direction in [CGFloat(1), -1] {
            var catchUp = MinimapCatchUp(scroll: 0.5, pointer: 0.5 - 0.3 * direction, gain: 10)
            var pointer = catchUp.pointer
            for _ in 0..<400 where !catchUp.isLocked {
                pointer += 0.002 * direction
                catchUp.move(to: pointer)
            }
            #expect(catchUp.isLocked)
        }
    }

    @Test func absolutePinsTheEnds() {
        #expect(MinimapCatchUp.absolute(pointerFraction: 0.02) == 0)
        #expect(MinimapCatchUp.absolute(pointerFraction: 0.98) == 1)
        #expect(abs(MinimapCatchUp.absolute(pointerFraction: 0.5) - 0.5) < 0.0001)
    }
}
