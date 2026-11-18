import CoreGraphics
import Testing
@testable import Plume

/// The rail sizes itself from the room between the pane's edge and the
/// bleed column, between its collapsed and normal widths, and a hover widens
/// a collapsed rail's bars to the normal width without moving their inset.
@MainActor
struct MinimapRailGeometryTests {
    private let bleedPadding: CGFloat = 12

    @Test func aReserveOnTheTrailingSideShrinksTheLeadingRoom() {
        let open = MinimapRailGeometry.room(viewportWidth: 1000, columnReserve: 0, bleedWidth: 700)
        let pinned = MinimapRailGeometry.room(viewportWidth: 1000, columnReserve: 280, bleedWidth: 700)
        #expect(open == 150)
        #expect(pinned == 10)
    }

    @Test func roomNeverGoesNegative() {
        #expect(MinimapRailGeometry.room(viewportWidth: 600, columnReserve: 300, bleedWidth: 700) == 0)
    }

    @Test func theRailIsCollapsedInsideTheBleedPadding() {
        let rail = MinimapRailGeometry(room: bleedPadding, bleedPadding: bleedPadding)
        #expect(rail.width == MinimapRailGeometry.collapsedWidth)
        #expect(rail.inset == MinimapRailGeometry.collapsedInset)
    }

    @Test func theRailIsNormalOnceItClearsThePaddingWithRoomToSpare() {
        let rail = MinimapRailGeometry(room: MinimapRailGeometry.normalCost, bleedPadding: bleedPadding)
        #expect(rail.width == MinimapRailGeometry.normalWidth)
        #expect(rail.inset == MinimapRailGeometry.normalInset)
        #expect(MinimapRailGeometry(room: 500, bleedPadding: bleedPadding) == rail)
    }

    @Test func theRailGrowsWithTheRoomInBetween() {
        let midRoom = (bleedPadding + MinimapRailGeometry.normalCost) / 2
        let rail = MinimapRailGeometry(room: midRoom, bleedPadding: bleedPadding)
        #expect(rail.width == (MinimapRailGeometry.collapsedWidth + MinimapRailGeometry.normalWidth) / 2)
    }

    @Test func aHoverWidensACollapsedRailToTheNormalWidthAndKeepsItsInset() {
        let rail = MinimapRailGeometry(room: 0, bleedPadding: bleedPadding)
        let hovered = rail.expanded(by: 1)
        #expect(hovered.width == MinimapRailGeometry.normalWidth)
        #expect(hovered.inset == rail.inset)
        #expect(rail.expanded(by: 0) == rail)
        #expect(rail.expanded(by: 0.5).width == (MinimapRailGeometry.collapsedWidth + MinimapRailGeometry.normalWidth) / 2)
    }

    @Test func aHoverLeavesANormalRailAlone() {
        let rail = MinimapRailGeometry(room: 500, bleedPadding: bleedPadding)
        #expect(rail.expanded(by: 1) == rail)
    }
}
