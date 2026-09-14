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

    @Test func aTableRoundTripsThroughTheCache() {
        let markdown = "| a | b |\n| :-- | --: |\n| 1 | 2 |"
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
        let styled = MarkdownCache.styledInline("Run `git status` now.", fontSize: 16)

        let chips = styled.segments.filter { $0.chipID != nil }
        #expect(chips.count == 1, "each code span should become one chip segment")
        #expect(styled.hasCode)
        #expect(styled.segments.contains { $0.chipID == nil }, "prose stays in its own segment, uncharted")

        let fullText = styled.segments.map { String($0.text.characters) }.joined()
        #expect(fullText.contains("git status"))
    }

    /// Copying an inline code span must yield exactly the source text — no
    /// thin-space padding smuggled in around the chip, since that padding
    /// would ride along into a pasted shell command.
    @Test func styledInlineCodeCopiesExactlyWithNoThinSpaces() {
        let styled = MarkdownCache.styledInline("Run `git status` now.", fontSize: 16)

        let string = styled.segments.map { String($0.text.characters) }.joined()
        #expect(string == "Run git status now.")
        #expect(!string.unicodeScalars.contains(Unicode.Scalar(0x2009)!))
    }

    /// The chip carries a kern on the character before it and on its own last
    /// character — the layout-level padding that stands in for the padding
    /// character the copy contract forbids.
    @Test func styledInlineKernsAroundAChip() {
        let styled = MarkdownCache.styledInline("Run `git status` now.", fontSize: 16)

        guard let chipIndex = styled.segments.firstIndex(where: { $0.chipID != nil }) else {
            Issue.record("expected one chip segment")
            return
        }
        let preceding = styled.segments[chipIndex - 1].text
        let precedingLastRun = preceding.runs[preceding.characters.index(before: preceding.endIndex)]
        #expect(precedingLastRun.kern == styled.pad)

        let chip = styled.segments[chipIndex].text
        let chipLastRun = chip.runs[chip.characters.index(before: chip.endIndex)]
        #expect(chipLastRun.kern == styled.pad)

        // Nothing else in either segment carries a kern.
        let precedingFirstRun = preceding.runs[preceding.startIndex]
        #expect(String(preceding.characters).count == 1 || precedingFirstRun.kern == nil)
    }

    /// A code span inside bold or italic carries both intents, so a chip has
    /// to be recognized by the code bit being present rather than by it being
    /// the only one — otherwise the span loses its mono font and its chip.
    @Test func styledInlineChipsABoldCodeSpan() {
        let styled = MarkdownCache.styledInline("**`x`**", fontSize: 16)

        #expect(styled.segments.filter { $0.chipID != nil }.count == 1)
        #expect(styled.hasCode)
    }

    /// Uppercasing a heading must keep the chip id on the code segment, since
    /// the renderer keys its chip grouping on that id.
    @Test func styledInlineUppercasedHeadingKeepsItsChip() {
        let styled = MarkdownCache.styledInline("See `git status` above", fontSize: 16)
        let uppercased = styled.uppercased()

        let originalChipID = styled.segments.first { $0.chipID != nil }?.chipID
        let uppercasedChip = uppercased.segments.first { $0.chipID != nil }
        #expect(uppercasedChip?.chipID == originalChipID)

        let fullText = uppercased.segments.map { String($0.text.characters) }.joined()
        #expect(fullText == "SEE GIT STATUS ABOVE")
    }

    /// The size is part of the key, so a font change cannot serve chips built
    /// at the previous size.
    @Test func styledInlineKeysOnSize() {
        let text = "Run `git status` now."
        let light = MarkdownCache.styledInline(text, fontSize: 16)
        let bigger = MarkdownCache.styledInline(text, fontSize: 24)

        let font: (StyledInline) -> Font? = { styled in
            styled.segments.first { $0.chipID != nil }?.text.runs.first?.font
        }
        #expect(font(bigger) != font(light), "a size change must rebuild the chips")
        #expect(bigger.pad != light.pad, "a size change must rebuild the chip padding")
    }
}
