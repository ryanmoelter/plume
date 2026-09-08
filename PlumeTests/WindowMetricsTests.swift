import Foundation
import Testing
@testable import Plume

struct WindowMetricsTests {
    @Test func sidebarMaximumWidthLeavesRoomForTheDetailFloor() {
        let width = WindowMetrics.sidebarMaximumWidth(windowWidth: 1200)
        #expect(width == 1200 - WindowMetrics.detailMinimumWidth)
    }

    @Test func sidebarMaximumWidthClampsToTheSidebarFloor() {
        let width = WindowMetrics.sidebarMaximumWidth(windowWidth: 400)
        #expect(width == WindowMetrics.sidebarMinimumWidth)
    }

    @Test func sidebarMaximumWidthNeverUndercutsTheMinimum() {
        for windowWidth in stride(from: CGFloat(0), through: 2000, by: 50) {
            #expect(WindowMetrics.sidebarMaximumWidth(windowWidth: windowWidth) >= WindowMetrics.sidebarMinimumWidth)
        }
    }
}
