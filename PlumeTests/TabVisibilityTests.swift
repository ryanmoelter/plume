import Foundation
import Testing
@testable import Plume

struct TabVisibilityTests {
    @Test func onlyTheSelectedTabIsOnScreenWithoutASplit() {
        let (selected, other) = (UUID(), UUID())

        #expect(TabVisibility.isOnScreen(tabID: selected, paneTabIDs: [selected]))
        #expect(!TabVisibility.isOnScreen(tabID: other, paneTabIDs: [selected]))
    }

    @Test func noTabIsOnScreenWithoutASelection() {
        #expect(!TabVisibility.isOnScreen(tabID: UUID(), paneTabIDs: []))
    }

    @Test func bothPanesAreOnScreenButOnlyOneIsFocused() {
        let (left, right, hidden) = (UUID(), UUID(), UUID())
        let panes = [left, right]

        #expect(TabVisibility.isOnScreen(tabID: left, paneTabIDs: panes))
        #expect(TabVisibility.isOnScreen(tabID: right, paneTabIDs: panes))
        #expect(!TabVisibility.isOnScreen(tabID: hidden, paneTabIDs: panes))
        #expect(TabVisibility.isFocused(tabID: right, selectedTabID: right))
        #expect(!TabVisibility.isFocused(tabID: left, selectedTabID: right))
    }
}
