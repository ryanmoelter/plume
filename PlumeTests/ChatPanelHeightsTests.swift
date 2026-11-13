import Foundation
import Testing

@testable import Plume

/// Each tab seeds its chat's first frame from its own last panel height, and
/// a forgotten tab's height goes with it.
@MainActor
struct ChatPanelHeightsTests {
    @Test func tabsKeepSeparateHeights() {
        let first = UUID(), second = UUID()

        ChatPanelHeights.record(120, forTab: first)
        ChatPanelHeights.record(80, forTab: second)

        #expect(ChatPanelHeights.height(forTab: first) == 120)
        #expect(ChatPanelHeights.height(forTab: second) == 80)
    }

    @Test func aForgottenTabStartsFromZero() {
        let tab = UUID()
        ChatPanelHeights.record(120, forTab: tab)

        ChatPanelHeights.forget(tabID: tab)

        #expect(ChatPanelHeights.height(forTab: tab) == 0)
    }
}
