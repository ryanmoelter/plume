import Foundation
import Testing
@testable import Plume

@MainActor
struct HomeIdleOrderTests {
    private func idle(_ title: String, openedAt: Date?) -> HomeFeed.Entry {
        HomeFeed.Entry(
            taskID: UUID(), tabID: UUID(), taskTitle: title, tabTitle: "Tab",
            status: .done, hasSession: true, lastOpenedAt: openedAt
        )
    }

    @Test func idleListsMostRecentlyOpenedFirst() {
        let now = Date()
        let feed = HomeFeed(entries: [
            idle("old", openedAt: now.addingTimeInterval(-100)),
            idle("never", openedAt: nil),
            idle("new", openedAt: now),
            idle("never2", openedAt: nil),
        ])
        #expect(feed.idle.map(\.taskTitle) == ["new", "old", "never", "never2"])
    }
}
