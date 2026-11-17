import AppKit
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

/// The hover's scroll in points: it keeps the map where it was when the
/// pane's travel changes mid-hover, and starts inside the travel however far
/// the map was scrolled before.
@MainActor
struct MinimapHoverScrollTests {
    @Test func aTravelChangeKeepsTheOffset() {
        var scroll = MinimapHoverScroll(offset: 100, travel: 200, pointer: 0.5, gain: 10)
        scroll.move(to: 0.5, travel: 400, gain: 10)

        #expect(scroll.offset == 100)
        #expect(scroll.travel == 400)
    }

    @Test func movingContinuesAfterATravelChange() {
        var scroll = MinimapHoverScroll(offset: 100, travel: 200, pointer: 0.5, gain: 10)
        scroll.move(to: 0.5, travel: 400, gain: 10)
        scroll.move(to: 0.6, travel: 400, gain: 10)

        #expect(scroll.offset > 100)
    }

    @Test func aShrinkingTravelClampsTheOffset() {
        var scroll = MinimapHoverScroll(offset: 150, travel: 200, pointer: 0.5, gain: 10)
        scroll.repin(travel: 100)
        #expect(scroll.offset == 100)
        scroll.repin(travel: 0)
        #expect(scroll.offset == 0)
    }

    @Test func repinningKeepsTheOffsetWhenItFits() {
        var scroll = MinimapHoverScroll(offset: 80, travel: 200, pointer: 0.5, gain: 10)
        scroll.repin(travel: 120)
        #expect(abs(scroll.offset - 80) < 0.0001)
    }

    @Test func entryClampsAnOffsetPastTheTravel() {
        #expect(MinimapHoverScroll(offset: 500, travel: 200, pointer: 0.5, gain: 10).offset == 200)
        #expect(MinimapHoverScroll(offset: -20, travel: 200, pointer: 0.5, gain: 10).offset == 0)
        #expect(MinimapHoverScroll(offset: 50, travel: 0, pointer: 0.5, gain: 10).offset == 0)
    }

    @Test func entryDoesNotMoveTheMap() {
        let scroll = MinimapHoverScroll(offset: 120, travel: 300, pointer: 0.9, gain: 10)
        #expect(abs(scroll.offset - 120) < 0.0001)
    }
}

/// A click on the hovered rail is the minimap's only within its footprint
/// and clear of the pane's edge, below the reveal exclusion and above the
/// composer, and only when it lands on the chat's own content.
@MainActor
struct MinimapClickZoneTests {
    private func accepts(distance: CGFloat = 8, y: CGFloat = 100) -> Bool {
        MinimapClickZone.accepts(distanceFromEdge: distance, y: y, footprint: 12, exclusionHeight: 40, drawableBottom: 300)
    }

    @Test func insideTheFootprintIsTheMinimaps() {
        #expect(accepts())
        #expect(accepts(distance: MinimapClickZone.edgeClearance))
        #expect(accepts(distance: 12))
    }

    @Test func thePanesEdgeIsLeftToTheDividers() {
        #expect(!accepts(distance: 0))
        #expect(!accepts(distance: MinimapClickZone.edgeClearance - 0.5))
    }

    @Test func onlyTheChatsContentGivesUpItsClick() {
        let document = ChatListDocumentView()
        let row = NSView()
        document.addSubview(row)
        let scroll = NSScrollView()
        scroll.documentView = document

        #expect(MinimapClickZone.isChatContent(row))
        #expect(MinimapClickZone.isChatContent(scroll))
        #expect(MinimapClickZone.isChatContent(scroll.contentView))
        #expect(!MinimapClickZone.isChatContent(NSView()))
        #expect(!MinimapClickZone.isChatContent(NSScrollView()))
        #expect(!MinimapClickZone.isChatContent(nil))
    }

    @Test func pastTheFootprintReachesTheChat() {
        #expect(!accepts(distance: 13))
    }

    @Test func theExclusionBandAndComposerReachTheChat() {
        #expect(!accepts(y: 39))
        #expect(!accepts(y: 301))
    }
}
