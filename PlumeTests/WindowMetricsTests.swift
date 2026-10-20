import Foundation
import Testing
@testable import Plume

struct WindowMetricsTests {
    @Test func sidebarMaximumWidthLeavesRoomForTheDetailFloor() {
        let width = WindowMetrics.sidebarMaximumWidth(windowWidth: 1200, paneCount: 1)
        #expect(width == 1200 - WindowMetrics.paneMinimumWidth)
    }

    @Test func sidebarMaximumWidthLeavesRoomForEveryPane() {
        let width = WindowMetrics.sidebarMaximumWidth(windowWidth: 1200, paneCount: 2)
        #expect(width == 1200 - 2 * WindowMetrics.paneMinimumWidth - SplitLayout.dividerWidth)
    }

    @Test func sidebarMaximumWidthClampsToTheSidebarFloor() {
        let width = WindowMetrics.sidebarMaximumWidth(windowWidth: 400, paneCount: 1)
        #expect(width == WindowMetrics.sidebarMinimumWidth)
    }

    @Test func sidebarMaximumWidthNeverUndercutsTheMinimum() {
        for windowWidth in stride(from: CGFloat(0), through: 2000, by: 50) {
            for paneCount in 1...2 {
                #expect(WindowMetrics.sidebarMaximumWidth(windowWidth: windowWidth, paneCount: paneCount) >= WindowMetrics.sidebarMinimumWidth)
            }
        }
    }

    @Test func theDetailFloorHoldsEveryPaneAndTheDividerBetween() {
        #expect(WindowMetrics.detailMinimumWidth(paneCount: 1) == WindowMetrics.paneMinimumWidth)
        #expect(WindowMetrics.detailMinimumWidth(paneCount: 2) == 2 * WindowMetrics.paneMinimumWidth + SplitLayout.dividerWidth)
        #expect(WindowMetrics.detailMinimumWidth(paneCount: 0) == WindowMetrics.paneMinimumWidth)
    }

    @Test func aSplitRaisesTheWindowFloorWithOrWithoutTheSidebar() {
        let extra = WindowMetrics.paneMinimumWidth + SplitLayout.dividerWidth
        #expect(WindowMetrics.minimumWidth(sidebarVisible: true, paneCount: 2) == WindowMetrics.minimumWidth(sidebarVisible: true, paneCount: 1) + extra)
        #expect(WindowMetrics.minimumWidth(sidebarVisible: false, paneCount: 2) == WindowMetrics.minimumWidth(sidebarVisible: false, paneCount: 1) + extra)
    }

    @Test func aSplitNeverCapsTheSidebarBelowItsCurrentWidth() {
        let width = WindowMetrics.sidebarMaximumWidth(windowWidth: 1000, paneCount: 2, sidebarWidth: 320)
        #expect(width == 320)
    }

    @Test func aSplitGrowsTheWindowAroundTheSidebar() {
        let floor = WindowMetrics.minimumWidth(sidebarVisible: true, paneCount: 2, sidebarWidth: 320)
        #expect(floor == 320 + WindowMetrics.detailMinimumWidth(paneCount: 2))
        #expect(WindowMetrics.sidebarMaximumWidth(windowWidth: floor, paneCount: 2, sidebarWidth: 320) == 320)
    }

    @Test func unsplitTheSidebarStillGivesWayToTheDetail() {
        #expect(WindowMetrics.sidebarMaximumWidth(windowWidth: 600, paneCount: 1, sidebarWidth: 320) == 600 - WindowMetrics.paneMinimumWidth)
        #expect(WindowMetrics.minimumWidth(sidebarVisible: true, paneCount: 1, sidebarWidth: 320) == WindowMetrics.sidebarMinimumWidth + WindowMetrics.paneMinimumWidth)
    }

    @Test func aHiddenSidebarAddsNothingToTheFloor() {
        #expect(WindowMetrics.minimumWidth(sidebarVisible: false, paneCount: 2, sidebarWidth: 320) == WindowMetrics.detailMinimumWidth(paneCount: 2))
    }
}
