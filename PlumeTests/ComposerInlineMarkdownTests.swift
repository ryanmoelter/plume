import Foundation
import Testing
@testable import Plume

struct ComposerInlineMarkdownTests {
    private static let style = ComposerTextStyle(bodySize: 14)

    private func run(_ text: String, style inline: ComposerInlineStyle = [], link: URL? = nil) -> NSAttributedString {
        NSAttributedString(string: text, attributes: Self.style.attributes(for: .paragraph, inline: inline, link: link))
    }

    private func markdown(of attributed: NSAttributedString) -> String {
        ComposerInlineMarkdown.markdown(from: attributed, range: NSRange(location: 0, length: attributed.length))
    }

    /// A backslash before a letter isn't a CommonMark escape (only ASCII
    /// punctuation escapes), so Foundation's parser leaves it untouched —
    /// and the serializer never inserts or removes one regardless.
    @Test func backslashesSurvive() {
        let attributed = ComposerInlineMarkdown.attributed(
            inline: "A literal backslash: C:\\path",
            kind: .paragraph,
            style: Self.style
        )
        #expect(markdown(of: attributed).contains("C:\\path"))
    }

    @Test func adjacentRunsOfTheSameStyleCoalesce() {
        let combined = NSMutableAttributedString()
        combined.append(run("a", style: .bold))
        combined.append(run("b", style: .bold))
        #expect(markdown(of: combined) == "**ab**")
    }

    @Test func nestedBoldInItalicClosesInTheRightOrder() {
        let combined = NSMutableAttributedString()
        combined.append(run("before ", style: .italic))
        combined.append(run("both", style: [.bold, .italic]))
        combined.append(run(" after", style: .italic))
        #expect(markdown(of: combined) == "*before **both** after*")
    }

    /// Both styles open together with no partial overlap, so the general
    /// nested open/close (bold outside, italic inside) collapses to the
    /// familiar triple-asterisk form.
    @Test func simultaneousBoldAndItalicCollapseToTripleAsterisk() {
        let attributed = run("both", style: [.bold, .italic])
        #expect(markdown(of: attributed) == "***both***")
    }

    @Test func codeSpanDelimiterIsLongerThanAnyInnerBacktickRun() {
        let attributed = run("a`b", style: .code)
        #expect(markdown(of: attributed) == "``a`b``")
    }

    @Test func codeSpanPadsWhenContentStartsWithABacktick() {
        let attributed = run("`leading", style: .code)
        #expect(markdown(of: attributed) == "`` `leading ``")
    }

    @Test func codeSpanPadsWhenContentEndsWithABacktick() {
        let attributed = run("trailing`", style: .code)
        #expect(markdown(of: attributed) == "`` trailing` ``")
    }

    @Test func linkWithParenthesesInTheURL() {
        let url = URL(string: "https://example.com/(page)")!
        let attributed = run("text", link: url)
        #expect(markdown(of: attributed) == "[text](https://example.com/(page))")
    }

    @Test func parseFailureFallsBackToTheLiteralString() {
        let attributed = ComposerInlineMarkdown.attributed(inline: "", kind: .paragraph, style: Self.style)
        #expect(attributed.length == 0)
    }

    @Test func plainTextNeedsNoDelimiters() {
        let attributed = ComposerInlineMarkdown.attributed(inline: "plain text", kind: .paragraph, style: Self.style)
        #expect(markdown(of: attributed) == "plain text")
    }
}
