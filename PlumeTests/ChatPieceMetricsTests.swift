import Foundation
import Testing
@testable import Plume

/// Covers the code block's scroll ceiling now that a header sits above the
/// scrolling region. The whole block — header plus code — must stay within
/// `maxCodeHeight`, since that ceiling is what keeps one lazy item from
/// towering over the rest (`docs/chat-list-hang.md`).
struct ChatPieceMetricsTests {
    @Test func theHeaderTakesItsHeightFromTheScrollingRegion() {
        #expect(ChatPieceMetrics.codeHeaderHeight > 0)
        #expect(
            ChatPieceMetrics.scrollingCodeHeight
                == ChatPieceMetrics.maxCodeHeight - ChatPieceMetrics.codeHeaderHeight
        )
    }

    /// The drawn height is the header plus the bounded scroller, so a block
    /// that scrolls still fits the ceiling the splitter assumes.
    @Test func aScrollingBlockFitsTheCeilingWithItsHeader() {
        let tall = String(repeating: "let x = 1\n", count: 200)
        #expect(ChatPieceMetrics.scrollsCode(tall))
        #expect(
            ChatPieceMetrics.codeHeaderHeight + ChatPieceMetrics.scrollingCodeHeight
                <= ChatPieceMetrics.maxCodeHeight
        )
    }

    @Test func aShortBlockDoesNotScroll() {
        #expect(!ChatPieceMetrics.scrollsCode("let x = 1"))
        #expect(!ChatPieceMetrics.scrollsCode(String(repeating: "a\n", count: 3)))
    }

    /// The estimate counts lines, so the threshold moves with the header
    /// rather than staying where it sat when code owned the whole ceiling.
    @Test func theHeaderLowersTheLineCountThatScrolls() {
        var lines = 1
        while !ChatPieceMetrics.scrollsCode(String(repeating: "x\n", count: lines)), lines < 500 {
            lines += 1
        }
        #expect(lines < 500)
        #expect(!ChatPieceMetrics.scrollsCode(String(repeating: "x\n", count: lines - 1)))
    }
}
