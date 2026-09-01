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
}
