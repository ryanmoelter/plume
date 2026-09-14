import Foundation
import Testing
@testable import Plume

struct ComposerInputRulesTests {
    private func context(
        _ paragraphText: String,
        kind: ComposerBlockKind = .paragraph,
        caret: Int? = nil,
        inserted: String,
        previousKind: ComposerBlockKind? = nil,
        codeRanges: [NSRange] = []
    ) -> ComposerInputRules.Context {
        ComposerInputRules.Context(
            paragraphText: paragraphText,
            kind: kind,
            caret: caret ?? (paragraphText as NSString).length,
            inserted: inserted,
            previousKind: previousKind,
            codeRanges: codeRanges
        )
    }

    // MARK: - Bullet

    @Test func bulletFiresOnHyphenSpace() {
        let edit = ComposerInputRules.edit(for: context("- ", inserted: " "))
        #expect(edit == .convertBlock(markerRange: NSRange(location: 0, length: 2), kind: .bullet(depth: 0)))
    }

    @Test func bulletFiresOnAsteriskAndPlusToo() {
        #expect(ComposerInputRules.edit(for: context("* ", inserted: " "))
            == .convertBlock(markerRange: NSRange(location: 0, length: 2), kind: .bullet(depth: 0)))
        #expect(ComposerInputRules.edit(for: context("+ ", inserted: " "))
            == .convertBlock(markerRange: NSRange(location: 0, length: 2), kind: .bullet(depth: 0)))
    }

    @Test func bulletDoesNotFireMidParagraph() {
        let edit = ComposerInputRules.edit(for: context("hello - ", inserted: " "))
        #expect(edit == nil)
    }

    @Test func bulletDoesNotFireWithLeadingWhitespace() {
        let edit = ComposerInputRules.edit(for: context(" - ", inserted: " "))
        #expect(edit == nil)
    }

    @Test func bulletDoesNotFireInCodeBlock() {
        let edit = ComposerInputRules.edit(for: context("- ", kind: .codeBlock(language: nil), inserted: " "))
        #expect(edit == nil)
    }

    @Test func bulletDoesNotFireInVerbatim() {
        let edit = ComposerInputRules.edit(for: context("- ", kind: .verbatim(), inserted: " "))
        #expect(edit == nil)
    }

    @Test func bulletDoesNotFireInHeading() {
        let edit = ComposerInputRules.edit(for: context("- ", kind: .heading(1), inserted: " "))
        #expect(edit == nil)
    }

    @Test func bulletInheritsDepthFromAPrecedingNumberedItem() {
        let edit = ComposerInputRules.edit(for: context("- ", inserted: " ", previousKind: .numbered(depth: 2, number: 1)))
        #expect(edit == .convertBlock(markerRange: NSRange(location: 0, length: 2), kind: .bullet(depth: 2)))
    }

    @Test func bulletStartsAtDepthZeroWithNoPrecedingListItem() {
        let edit = ComposerInputRules.edit(for: context("- ", inserted: " ", previousKind: .paragraph))
        #expect(edit == .convertBlock(markerRange: NSRange(location: 0, length: 2), kind: .bullet(depth: 0)))
    }

    // MARK: - Numbered

    @Test func numberedFiresOnDigitsDotSpace() {
        let edit = ComposerInputRules.edit(for: context("42. ", inserted: " "))
        #expect(edit == .convertBlock(markerRange: NSRange(location: 0, length: 4), kind: .numbered(depth: 0, number: 42)))
    }

    @Test func numberedDoesNotFireMidParagraph() {
        let edit = ComposerInputRules.edit(for: context("see 1. ", inserted: " "))
        #expect(edit == nil)
    }

    @Test func numberedDoesNotFireWithLeadingWhitespace() {
        let edit = ComposerInputRules.edit(for: context(" 1. ", inserted: " "))
        #expect(edit == nil)
    }

    @Test func numberedDoesNotFireInCodeBlock() {
        let edit = ComposerInputRules.edit(for: context("1. ", kind: .codeBlock(language: nil), inserted: " "))
        #expect(edit == nil)
    }

    @Test func numberedInheritsDepthFromAPrecedingBulletItem() {
        let edit = ComposerInputRules.edit(for: context("1. ", inserted: " ", previousKind: .bullet(depth: 1)))
        #expect(edit == .convertBlock(markerRange: NSRange(location: 0, length: 3), kind: .numbered(depth: 1, number: 1)))
    }

    // MARK: - Heading

    @Test func headingLevelsOneThroughSixFire() {
        for level in 1...6 {
            let marker = String(repeating: "#", count: level) + " "
            let edit = ComposerInputRules.edit(for: context(marker, inserted: " "))
            #expect(edit == .convertBlock(markerRange: NSRange(location: 0, length: level + 1), kind: .heading(level)))
        }
    }

    @Test func sevenHashesDoesNotFire() {
        let marker = String(repeating: "#", count: 7) + " "
        let edit = ComposerInputRules.edit(for: context(marker, inserted: " "))
        #expect(edit == nil)
    }

    @Test func headingKeepsTrailingTextAfterTheMarker() {
        let edit = ComposerInputRules.edit(for: context("## Section", caret: 3, inserted: " "))
        #expect(edit == .convertBlock(markerRange: NSRange(location: 0, length: 3), kind: .heading(2)))
    }

    @Test func headingDoesNotFireMidParagraph() {
        let edit = ComposerInputRules.edit(for: context("a # ", inserted: " "))
        #expect(edit == nil)
    }

    @Test func headingDoesNotFireInAQuote() {
        let edit = ComposerInputRules.edit(for: context("# ", kind: .quote, inserted: " "))
        #expect(edit == nil)
    }

    // MARK: - Quote

    @Test func quoteFiresOnGreaterThanSpace() {
        let edit = ComposerInputRules.edit(for: context("> ", inserted: " "))
        #expect(edit == .convertBlock(markerRange: NSRange(location: 0, length: 2), kind: .quote))
    }

    @Test func quoteDoesNotFireMidParagraph() {
        let edit = ComposerInputRules.edit(for: context("a > ", inserted: " "))
        #expect(edit == nil)
    }

    @Test func quoteDoesNotFireInACodeBlock() {
        let edit = ComposerInputRules.edit(for: context("> ", kind: .codeBlock(language: nil), inserted: " "))
        #expect(edit == nil)
    }

    // MARK: - Code fence

    @Test func tripleBacktickFencesConvertToABareCodeBlock() {
        let edit = ComposerInputRules.edit(for: context("```", inserted: "`"))
        guard case let .convertBlock(markerRange, kind) = edit else {
            Issue.record("expected a convertBlock edit, got \(String(describing: edit))")
            return
        }
        #expect(markerRange == NSRange(location: 0, length: 3))
        guard case let .codeBlock(language) = kind.kind else {
            Issue.record("expected a codeBlock kind, got \(kind.kind)")
            return
        }
        #expect(language == nil)
    }

    @Test func fenceDoesNotFireWhileTypingWithoutCompletingTheThirdBacktick() {
        let edit = ComposerInputRules.edit(for: context("``", inserted: "`"))
        #expect(edit == nil)
    }

    @Test func fenceDoesNotRefireWhileTypingALanguageAfterward() {
        // The third backtick already converted the paragraph's kind, so by
        // the time "s" of "swift" lands the caller's kind is no longer
        // .paragraph — but even checked in isolation against .paragraph,
        // typing a non-backtick character never satisfies the fence rule.
        let edit = ComposerInputRules.edit(for: context("```s", inserted: "s"))
        #expect(edit == nil)
    }

    @Test func fenceDoesNotFireInACodeBlock() {
        let edit = ComposerInputRules.edit(for: context("```", kind: .codeBlock(language: nil), inserted: "`"))
        #expect(edit == nil)
    }

    // MARK: - Bold

    @Test func boldFiresOnClosingDoubleAsterisk() {
        let edit = ComposerInputRules.edit(for: context("**bold**", inserted: "*"))
        #expect(edit == .convertInline(
            openRange: NSRange(location: 0, length: 2),
            closeRange: NSRange(location: 6, length: 2),
            style: .bold
        ))
    }

    @Test func boldDoesNotFireWithEmptyContent() {
        let edit = ComposerInputRules.edit(for: context("****", inserted: "*"))
        #expect(edit == nil)
    }

    @Test func boldDoesNotFireWithWhitespaceTouchingADelimiter() {
        let edit = ComposerInputRules.edit(for: context("** bold**", inserted: "*"))
        #expect(edit == nil)
    }

    // MARK: - Italic

    @Test func italicFiresOnClosingSingleAsterisk() {
        let edit = ComposerInputRules.edit(for: context("*italic*", inserted: "*"))
        #expect(edit == .convertInline(
            openRange: NSRange(location: 0, length: 1),
            closeRange: NSRange(location: 7, length: 1),
            style: .italic
        ))
    }

    @Test func italicFiresOnClosingUnderscore() {
        let edit = ComposerInputRules.edit(for: context("_italic_", inserted: "_"))
        #expect(edit == .convertInline(
            openRange: NSRange(location: 0, length: 1),
            closeRange: NSRange(location: 7, length: 1),
            style: .italic
        ))
    }

    @Test func underscoresInsideAWordNeverConvert() {
        // Caret lands right after the second underscore — as if it were
        // just typed into existing "foo_barbaz" text — so the preceding
        // character ('o' of "bar") is what fails the boundary check.
        let edit = ComposerInputRules.edit(for: context("foo_bar_baz", caret: 8, inserted: "_"))
        #expect(edit == nil)
    }

    @Test func underscoreAtWordBoundaryStillConvertsWhenFollowedByPunctuation() {
        let edit = ComposerInputRules.edit(for: context("say _hi_.", caret: 8, inserted: "_"))
        #expect(edit == .convertInline(
            openRange: NSRange(location: 4, length: 1),
            closeRange: NSRange(location: 7, length: 1),
            style: .italic
        ))
    }

    @Test func asteriskBulletMarkerNeverReadsAsItalic() {
        // "* " at paragraph start is a bullet (block rule wins outright,
        // since it's tried first and inline rules are never consulted).
        let bulletEdit = ComposerInputRules.edit(for: context("* ", inserted: " "))
        #expect(bulletEdit == .convertBlock(markerRange: NSRange(location: 0, length: 2), kind: .bullet(depth: 0)))
    }

    @Test func asteriskEmphasisStillConvertsWhenItDoesNotLookLikeABulletMarker() {
        let edit = ComposerInputRules.edit(for: context("*emph*", inserted: "*"))
        #expect(edit == .convertInline(
            openRange: NSRange(location: 0, length: 1),
            closeRange: NSRange(location: 5, length: 1),
            style: .italic
        ))
    }

    @Test func multiByteCharacterBeforeTheMarkerIsCountedInUtf16Units() {
        // "😀" is a surrogate pair — 2 UTF-16 units — so the bold delimiters
        // sit 3 units in (emoji + space), not 1.
        let edit = ComposerInputRules.edit(for: context("😀 **bold**", inserted: "*"))
        #expect(edit == .convertInline(
            openRange: NSRange(location: 3, length: 2),
            closeRange: NSRange(location: 9, length: 2),
            style: .bold
        ))
    }

    // MARK: - Inline code

    @Test func inlineCodeFiresOnClosingBacktick() {
        let edit = ComposerInputRules.edit(for: context("`code`", inserted: "`"))
        #expect(edit == .convertInline(
            openRange: NSRange(location: 0, length: 1),
            closeRange: NSRange(location: 5, length: 1),
            style: .code
        ))
    }

    @Test func inlineCodeDoesNotFireWithEmptyContent() {
        let edit = ComposerInputRules.edit(for: context("``", inserted: "`"))
        #expect(edit == nil)
    }

    @Test func aRunOfTwoBackticksAtTheCloserNeverTriggersInlineCode() {
        let edit = ComposerInputRules.edit(for: context("``code``", inserted: "`"))
        #expect(edit == nil)
    }

    // MARK: - Emphasis inside an existing code range

    @Test func emphasisDelimiterIntersectingACodeRangeDoesNotFire() {
        let edit = ComposerInputRules.edit(for: context(
            "a*b*c", caret: 4, inserted: "*", codeRanges: [NSRange(location: 1, length: 3)]
        ))
        #expect(edit == nil)
    }

    @Test func emphasisOutsideACodeRangeStillFires() {
        let edit = ComposerInputRules.edit(for: context(
            "a*b*c", caret: 4, inserted: "*", codeRanges: [NSRange(location: 4, length: 1)]
        ))
        #expect(edit == .convertInline(
            openRange: NSRange(location: 1, length: 1),
            closeRange: NSRange(location: 3, length: 1),
            style: .italic
        ))
    }

    // MARK: - Link

    @Test func linkFiresOnClosingParenthesis() {
        let markdown = "[text](https://example.com)"
        let edit = ComposerInputRules.edit(for: context(markdown, inserted: ")"))
        #expect(edit == .convertLink(
            range: NSRange(location: 0, length: (markdown as NSString).length),
            text: "text",
            url: URL(string: "https://example.com")!
        ))
    }

    @Test func linkWithASpaceInTheUrlDoesNotFire() {
        let edit = ComposerInputRules.edit(for: context("[text](https://exa mple.com)", inserted: ")"))
        #expect(edit == nil)
    }

    @Test func linkDoesNotFireInACodeBlock() {
        let edit = ComposerInputRules.edit(for: context(
            "[text](https://example.com)", kind: .codeBlock(language: nil), inserted: ")"
        ))
        #expect(edit == nil)
    }
}
