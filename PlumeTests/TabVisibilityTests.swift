import Foundation
import Testing
@testable import Plume

struct TabVisibilityTests {
    @Test func onlyTheSelectedTabIsOnScreen() {
        let (selected, other) = (UUID(), UUID())

        #expect(TabVisibility.isOnScreen(tabID: selected, selectedTabID: selected))
        #expect(!TabVisibility.isOnScreen(tabID: other, selectedTabID: selected))
    }

    @Test func noTabIsOnScreenWithoutASelection() {
        #expect(!TabVisibility.isOnScreen(tabID: UUID(), selectedTabID: nil))
    }
}
