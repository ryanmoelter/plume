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

    @Test func bleedIsWiderThanContentAtEverySize() {
        for size in stride(from: 9.0, through: 32.0, by: 1.0) {
            #expect(ChatMetrics.maxBleedWidth(forFontSize: size) > ChatMetrics.maxContentWidth(forFontSize: size))
        }
    }

    @Test func bleedScalesWithFontSize() {
        #expect(ChatMetrics.maxBleedWidth(forFontSize: 16) == 800)
        #expect(ChatMetrics.maxBleedWidth(forFontSize: 13) == 650)
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
