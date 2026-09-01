import Foundation
import Testing
@testable import Plume

struct ChatMetricsTests {
    @Test func maxContentWidthScalesWithFontSize() {
        #expect(ChatMetrics.maxContentWidth(forFontSize: 16) == 640)
        #expect(ChatMetrics.maxContentWidth(forFontSize: 13) == 520)
    }

    @Test func maxContentWidthGrowsWithLargerFonts() {
        let small = ChatMetrics.maxContentWidth(forFontSize: 11)
        let large = ChatMetrics.maxContentWidth(forFontSize: 28)
        #expect(large > small)
    }

    @Test func bottomPaddingScalesWithFontSize() {
        #expect(ChatMetrics.bottomPadding(forFontSize: 16) == 72)
        #expect(ChatMetrics.bottomPadding(forFontSize: 13) == 58.5)
    }

    @Test func bottomPaddingGrowsWithLargerFonts() {
        let small = ChatMetrics.bottomPadding(forFontSize: 11)
        let large = ChatMetrics.bottomPadding(forFontSize: 28)
        #expect(large > small)
    }
}
