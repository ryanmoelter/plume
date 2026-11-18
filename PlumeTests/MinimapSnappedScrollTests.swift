import Foundation
import Testing
@testable import Plume

/// The snapped scroll holds the drawn offset while the hovered row stays the
/// same, steps to the catch-up's offset when it changes, and always hovers
/// the row drawn under the pointer, so it settles rather than flipping
/// between two rows at a boundary.
@MainActor
struct MinimapSnappedScrollTests {
    /// Rows every 10 pt of content, from row 0 at the top.
    private static func rowAt(pointerY: CGFloat) -> (CGFloat) -> String? {
        { offset in "r\(max(0, Int(((pointerY + offset) / 10).rounded())))" }
    }

    private static func step(hovered: String?, displayed: CGFloat, target: CGFloat, pointerY: CGFloat) -> MinimapSnappedScroll.Step {
        MinimapSnappedScroll.step(
            hoveredRowID: hovered,
            displayed: displayed,
            target: target,
            rowAt: rowAt(pointerY: pointerY)
        )
    }

    @Test func theMapHoldsStillWhileTheRowIsUnchanged() {
        let step = Self.step(hovered: "r3", displayed: 0, target: 50, pointerY: 31)
        #expect(step == MinimapSnappedScroll.Step(rowID: "r3", offset: 0))
    }

    @Test func aRowChangeStepsToTheTarget() {
        let step = Self.step(hovered: "r3", displayed: 0, target: 20, pointerY: 36)
        #expect(step == MinimapSnappedScroll.Step(rowID: "r6", offset: 20))
    }

    @Test func theFirstHoverTakesTheTarget() {
        let step = Self.step(hovered: nil, displayed: 0, target: 12, pointerY: 31)
        #expect(step == MinimapSnappedScroll.Step(rowID: "r4", offset: 12))
    }

    @Test func aStepThatWouldLandBackOnTheRowKeepsTheOffset() {
        let step = Self.step(hovered: "r3", displayed: 0, target: -2, pointerY: 35.1)
        #expect(step == MinimapSnappedScroll.Step(rowID: "r4", offset: 0))
    }

    @Test func theDeadZoneStillHoldsTheMap() {
        var scroll = MinimapHoverScroll(offset: 100, travel: 400, pointer: 0.6, gain: 10, entryY: 200, deadZoneRadius: 16)
        var hovered: String? = "r30"
        var displayed: CGFloat = 100
        for (pointer, y) in [(0.62, 205.0), (0.58, 190.0), (0.64, 214.0)] {
            scroll.move(to: pointer, pointerY: y, travel: 400, gain: 10)
            let step = Self.step(hovered: hovered, displayed: displayed, target: scroll.offset, pointerY: y)
            hovered = step.rowID
            displayed = step.offset
            #expect(displayed == 100)
        }
        #expect(hovered == "r31")
    }

    @Test func jitterAtARowBoundarySettles() {
        var hovered: String? = "r3"
        var displayed: CGFloat = 0
        var changes = 0
        for index in 0..<20 {
            let y: CGFloat = index.isMultiple(of: 2) ? 35.1 : 34.9
            let step = Self.step(hovered: hovered, displayed: displayed, target: -2, pointerY: y)
            if step.rowID != hovered { changes += 1 }
            hovered = step.rowID
            displayed = step.offset
        }
        #expect(changes <= 2)
        #expect(displayed == -2)
    }

    @Test func theHoveredRowIsAlwaysTheOneDrawnUnderThePointer() {
        var hovered: String?
        var displayed: CGFloat = 0
        var target: CGFloat = 0
        var y: CGFloat = 50
        for index in 0..<200 {
            let delta = CGFloat((index * 37) % 11) - 5
            y += delta
            target += delta * (index.isMultiple(of: 3) ? 1.8 : 0.6)
            let step = Self.step(hovered: hovered, displayed: displayed, target: target, pointerY: y)
            #expect(Self.rowAt(pointerY: y)(step.offset) == step.rowID)
            let again = Self.step(hovered: step.rowID, displayed: step.offset, target: target, pointerY: y)
            #expect(again == step)
            if step.rowID == hovered { #expect(step.offset == displayed) }
            hovered = step.rowID
            displayed = step.offset
        }
    }
}
