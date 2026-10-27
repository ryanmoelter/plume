import Foundation
import Testing
@testable import Plume

struct ReferenceChipTextTests {
    private let chip = String(ReferenceChipText.placeholder)

    private func rendered(_ markdown: String) throws -> String {
        let parsed = try AttributedString(
            markdown: markdown,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )
        return String(parsed.characters)
    }

    // MARK: - Titles

    @Test func aTitleAtTheLimitIsKept() {
        let title = String(repeating: "a", count: 40)
        #expect(ReferenceChipText.truncatedTitle(title) == title)
    }

    @Test func aTitlePastTheLimitIsCutToAnEllipsis() {
        let cut = ReferenceChipText.truncatedTitle(String(repeating: "a", count: 41))
        #expect(cut == String(repeating: "a", count: 39) + "…")
        #expect(cut.count == 40)
    }

    @Test func theCutNeverEndsOnASpace() {
        let title = String(repeating: "a", count: 38) + " b" + String(repeating: "c", count: 10)
        #expect(ReferenceChipText.truncatedTitle(title) == String(repeating: "a", count: 38) + "…")
    }

    @Test func theCutKeepsAnEmojiWhole() {
        let title = String(repeating: "a", count: 38) + "👨‍👩‍👧" + String(repeating: "b", count: 5)
        #expect(ReferenceChipText.truncatedTitle(title) == String(repeating: "a", count: 38) + "👨‍👩‍👧…")
    }

    @Test func whitespaceRunsCollapse() {
        #expect(ReferenceChipText.truncatedTitle("  Fix\nthe \t layout  ") == "Fix the layout")
    }

    @Test(arguments: ["Fix *bold* and _em_", "Use `code` here", "A [bracket] \\ slash", "<tag> & | pipe!", "~~struck~~"])
    func anEscapedTitleRendersAsWritten(title: String) throws {
        let markdown = "[\(ReferenceChipText.chipLabel(title))](https://example.com)"
        #expect(try rendered(markdown) == chip + title)
    }

    // MARK: - Rewriting

    private func rewrite(_ text: String, titles: [String: String]) -> String {
        ReferenceChipText.rewrite(text) { titles[$0] }
    }

    @Test func aLinkWithATitleIsRewritten() {
        let text = "See [PLUME-1](https://linear.app/p/issue/PLUME-1) now."
        let rewritten = rewrite(text, titles: ["https://linear.app/p/issue/PLUME-1": "Add chips"])
        #expect(rewritten == "See [\(chip)Add chips](https://linear.app/p/issue/PLUME-1) now.")
    }

    @Test func aLinkWithNoTitleIsLeftAlone() {
        let text = "See [PLUME-1](https://linear.app/p/issue/PLUME-1)."
        #expect(rewrite(text, titles: [:]) == text)
    }

    @Test func imagesAndCodeAreLeftAlone() {
        let text = "![shot](a.png) and `[x](a.png)`"
        #expect(rewrite(text, titles: ["a.png": "Title"]) == text)
    }

    @Test func anAngleBracketDestinationStaysByteIdentical() {
        let text = "[My Notes.md](<My Notes.md>)"
        #expect(rewrite(text, titles: ["<My Notes.md>": "My Notes.md"]) == "[\(chip)My Notes.md](<My Notes.md>)")
    }

    @Test func everyLinkIsRewrittenInPlace() {
        let text = "[#1](https://github.com/o/r/pull/1), [#2](https://github.com/o/r/pull/2) and [x](https://example.com)"
        let rewritten = rewrite(text, titles: [
            "https://github.com/o/r/pull/1": "One",
            "https://github.com/o/r/pull/2": "Two"
        ])
        #expect(rewritten == "[\(chip)One](https://github.com/o/r/pull/1), [\(chip)Two](https://github.com/o/r/pull/2) and [x](https://example.com)")
    }

    @Test func restoringPutsBackTheCanonicalLabel() {
        let text = "[\(chip)Add chips](https://linear.app/p/issue/PLUME-1/slug), [\(chip)Fix](https://github.com/o/r/pull/7), [\(chip)A\\_B.swift](Sources/A_B.swift#L4) and [x](https://example.com)"
        #expect(ReferenceChipText.restoringCanonical(in: text)
            == "[PLUME-1](https://linear.app/p/issue/PLUME-1/slug), [#7](https://github.com/o/r/pull/7), [A\\_B.swift](Sources/A_B.swift#L4) and [x](https://example.com)")
    }

    @Test func aFolderKeepsItsTrailingSlash() {
        #expect(ReferenceChipText.restoringCanonical(in: "[\(chip)Chat](Plume/UI/Chat/)") == "[Chat/](Plume/UI/Chat/)")
    }

    // MARK: - Link ranges

    @Test func linkRangesSplitLabelAndDestination() throws {
        let text = "a [label](dest) b ![img](pic.png)"
        let ns = text as NSString
        let links = MarkdownHighlighter.linkRanges(in: text)
        try #require(links.count == 2)
        #expect(ns.substring(with: links[0].whole) == "[label](dest)")
        #expect(ns.substring(with: links[0].label) == "label")
        #expect(ns.substring(with: links[0].destination) == "dest")
        #expect(!links[0].isImage)
        #expect(ns.substring(with: links[1].label) == "img")
        #expect(links[1].isImage)
    }

    @Test func linkRangesSkipCodeSpans() {
        #expect(MarkdownHighlighter.linkRanges(in: "`[a](b)` plain").isEmpty)
    }

    @Test func linkRangesKeepAnglesAndEscapes() throws {
        let text = "[a \\] b](<x y.md>)"
        let ns = text as NSString
        let link = try #require(MarkdownHighlighter.linkRanges(in: text).first)
        #expect(ns.substring(with: link.label) == "a \\] b")
        #expect(ns.substring(with: link.destination) == "<x y.md>")
    }
}
