import Foundation
import Testing
@testable import Plume

/// Writing a parsed block back to markdown, which is what a piece the
/// splitter divided copies. A block that stayed whole copies its own lines
/// instead, so the round trip only has to be faithful, not byte-identical.
struct MarkdownSourceTests {
    private func roundTrip(_ text: String) -> [MarkdownBlock] {
        MarkdownBlock.parse(MarkdownBlock.parse(text).map(MarkdownSource.markdown(of:)).joined(separator: "\n\n"))
    }

    @Test func aTableSurvivesTheRoundTrip() {
        let source = """
        | Name | Count |
        | --- | ---: |
        | one | 1 |
        | two | 2 |
        """
        #expect(roundTrip(source) == MarkdownBlock.parse(source))
    }

    @Test func aTableCellsOwnPipeIsEscaped() {
        let block = MarkdownBlock.table(
            header: ["a"],
            alignments: [.leading],
            rows: [["x | y"]]
        )
        #expect(MarkdownSource.markdown(of: block).contains("x \\| y"))
        #expect(roundTrip(MarkdownSource.markdown(of: block)) == [block])
    }

    @Test func alignmentMarkersAreKept() {
        let block = MarkdownBlock.table(
            header: ["l", "c", "r"],
            alignments: [.leading, .center, .trailing],
            rows: []
        )
        #expect(roundTrip(MarkdownSource.markdown(of: block)) == [block])
    }

    @Test func aNumberedListKeepsItsStart() {
        let segment = ListSegment(kind: .numbered, items: ["third"], startNumber: 3)
        #expect(MarkdownSource.markdown(of: segment) == "3. third")
    }

    @Test func aBulletListTakesDashes() {
        let segment = ListSegment(kind: .bullet, items: ["one", "two"])
        #expect(MarkdownSource.markdown(of: segment) == "- one\n- two")
    }

    @Test func aCodeBlockTakesItsLanguage() {
        let segment = CodeSegment(language: "swift", code: "let x = 1")
        #expect(MarkdownSource.markdown(of: segment) == "```swift\nlet x = 1\n```")
        #expect(MarkdownBlock.parse(MarkdownSource.markdown(of: segment))
            == [.codeBlock(language: "swift", code: "let x = 1")])
    }

    /// A fence inside the code would close the block early at three backticks.
    /// `MarkdownBlock` reads only three, so this is for the editor the text is
    /// pasted into rather than for a round trip through here.
    @Test func aCodeBlockHoldingAFenceTakesALongerOne() {
        let segment = CodeSegment(language: "md", code: "```\nnested\n```")
        #expect(MarkdownSource.markdown(of: segment).hasPrefix("````md\n"))
    }

    @Test func aQuoteIsPrefixedOnEveryLine() {
        #expect(MarkdownSource.markdown(of: .quote("one\ntwo")) == "> one\n> two")
    }

    @Test func aHeadingKeepsItsLevel() {
        #expect(MarkdownSource.markdown(of: .heading(level: 3, text: "Title")) == "### Title")
    }

    @Test func nonMarkdownContentOffersNothing() {
        #expect(MarkdownSource.markdown(of: .thinking("hm")) == nil)
        #expect(MarkdownSource.markdown(of: .working) == nil)
    }
}
