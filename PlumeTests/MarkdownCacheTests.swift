import Testing
import Foundation
import SwiftUI
@testable import Plume

/// The cache sits on the scroll path, so these cover correctness first and
/// the speedup second.
@MainActor
struct MarkdownCacheTests {
    init() { MarkdownCache.reset() }

    @Test func blocksMatchAnUncachedParse() {
        let markdown = """
        # Heading

        A paragraph with **bold** text.

        - one
        - two
        """
        #expect(MarkdownCache.blocks(for: markdown) == MarkdownBlock.parse(markdown))
    }

    @Test func aRepeatedLookupReturnsTheSameValue() {
        let markdown = "# Title\n\nBody"
        let first = MarkdownCache.blocks(for: markdown)
        let second = MarkdownCache.blocks(for: markdown)
        #expect(first == second)
    }

    @Test func differentStringsGetDifferentResults() {
        #expect(MarkdownCache.blocks(for: "# One") != MarkdownCache.blocks(for: "# Two"))
    }

    @Test func inlineParsingResolvesEmphasis() {
        let plain = MarkdownCache.inline("just text")
        #expect(String(plain.characters) == "just text")

        // The markers are consumed, which is what proves it parsed rather
        // than falling back to the literal string.
        let bold = MarkdownCache.inline("a **bold** word")
        #expect(String(bold.characters) == "a bold word")
    }

    @Test func inlineKeepsSingleNewlinesInsideABlock() {
        let text = "first line\nsecond line"
        #expect(String(MarkdownCache.inline(text).characters).contains("\n"))
    }

    @Test func anEmptyStringIsHandled() {
        #expect(MarkdownCache.blocks(for: "").isEmpty)
        #expect(String(MarkdownCache.inline("").characters).isEmpty)
    }

    /// The cache is bounded, and crossing the bound must not lose
    /// correctness — only the cached speedup.
    @Test func exceedingTheLimitStillReturnsCorrectResults() {
        for index in 0..<600 {
            _ = MarkdownCache.blocks(for: "# Heading \(index)")
        }
        #expect(MarkdownCache.blocks(for: "# Heading 42") == MarkdownBlock.parse("# Heading 42"))
        #expect(MarkdownCache.blocks(for: "# fresh") == MarkdownBlock.parse("# fresh"))
    }

    /// Guards the reason the cache exists. Inline parsing measured ~0.083ms a
    /// block uncached, so a screenful re-parsed every body pass overran the
    /// frame budget on its own.
    @Test func repeatedInlineParsingIsCheapAfterTheFirstPass() {
        let paragraphs = (0..<200).map { "Paragraph \($0) with **bold** and `code` and a [link](https://example.com)." }

        let cold = Date()
        for text in paragraphs { _ = MarkdownCache.inline(text) }
        let coldMs = Date().timeIntervalSince(cold) * 1000

        let warm = Date()
        for _ in 0..<10 {
            for text in paragraphs { _ = MarkdownCache.inline(text) }
        }
        let warmMsPerPass = Date().timeIntervalSince(warm) * 1000 / 10

        #expect(warmMsPerPass < coldMs / 4, "cached pass \(warmMsPerPass)ms vs cold \(coldMs)ms")
    }

    @Test func styledInlineTintsCodeSpansAndLeavesProseAlone() {
        let styled = MarkdownCache.styledInline(
            "Run `git status` now.",
            fontSize: 16,
            tint: .gray
        )

        let tinted = styled.runs.filter { $0.backgroundColor != nil }
        #expect(tinted.count == 1, "each code span should paint as one unbroken run")
        #expect(String(styled.characters).contains("git status"))
        #expect(styled.runs.contains { $0.backgroundColor == nil }, "prose stays untinted")
    }

    /// The tint and size are part of the key, so a light/dark switch or a font
    /// change cannot serve chips built for the previous appearance.
    @Test func styledInlineKeysOnTintAndSize() {
        let text = "Run `git status` now."
        let light = MarkdownCache.styledInline(text, fontSize: 16, tint: .white)
        let dark = MarkdownCache.styledInline(text, fontSize: 16, tint: .black)
        let bigger = MarkdownCache.styledInline(text, fontSize: 24, tint: .white)

        let tint: (AttributedString) -> Color? = { string in
            string.runs.compactMap(\.backgroundColor).first
        }
        #expect(tint(light) != tint(dark))
        #expect(tint(bigger) == tint(light))

        let font: (AttributedString) -> Font? = { string in
            string.runs.first { $0.backgroundColor != nil }?.font
        }
        #expect(font(bigger) != font(light), "a size change must rebuild the chips")
    }
}
