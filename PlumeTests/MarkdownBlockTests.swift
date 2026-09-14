import Foundation
import Testing
@testable import Plume

struct MarkdownBlockTests {
    private static func bullets(_ texts: [String], depth: Int = 0) -> MarkdownBlock {
        .list(texts.map { MarkdownBlock.ListItem(text: $0, depth: depth) })
    }

    private static func numbers(_ texts: [String], from start: Int = 1, depth: Int = 0) -> MarkdownBlock {
        .list(texts.enumerated().map { offset, text in
            MarkdownBlock.ListItem(text: text, depth: depth, number: start + offset)
        })
    }

    @Test func fenceWithLanguage() {
        let blocks = MarkdownBlock.parse("```swift\nlet x = 1\n```")
        #expect(blocks == [.codeBlock(language: "swift", code: "let x = 1")])
    }

    @Test func fenceWithoutLanguage() {
        let blocks = MarkdownBlock.parse("```\nplain\n```")
        #expect(blocks == [.codeBlock(language: nil, code: "plain")])
    }

    @Test func unterminatedFenceKeepsContent() {
        let blocks = MarkdownBlock.parse("```swift\nlet x = 1\nlet y = 2")
        #expect(blocks == [.codeBlock(language: "swift", code: "let x = 1\nlet y = 2")])
    }

    /// A four-backtick opener holds a three-backtick line without closing
    /// early, and its extra backtick is part of the fence, not the language.
    @Test func aFourBacktickFenceHoldsAThreeBacktickLine() {
        let blocks = MarkdownBlock.parse("````md\n```\nnested\n```\n````")
        #expect(blocks == [.codeBlock(language: "md", code: "```\nnested\n```")])
    }

    @Test func aFourBacktickFenceWithNoLanguage() {
        let blocks = MarkdownBlock.parse("````\n```\nnested\n```\n````")
        #expect(blocks == [.codeBlock(language: nil, code: "```\nnested\n```")])
    }

    @Test func aLongerClosingFenceStillCloses() {
        let blocks = MarkdownBlock.parse("```swift\ncode\n`````")
        #expect(blocks == [.codeBlock(language: "swift", code: "code")])
    }

    @Test func aTildeFenceOfFourAlsoHoldsAShorterTildeLine() {
        let blocks = MarkdownBlock.parse("~~~~md\n~~~\nnested\n~~~\n~~~~")
        #expect(blocks == [.codeBlock(language: "md", code: "~~~\nnested\n~~~")])
    }

    @Test func headingLevels() {
        for level in 1...6 {
            let hashes = String(repeating: "#", count: level)
            let blocks = MarkdownBlock.parse("\(hashes) Title")
            #expect(blocks == [.heading(level: level, text: "Title")])
        }
    }

    @Test func bulletList() {
        let blocks = MarkdownBlock.parse("- one\n- two\n- three")
        #expect(blocks == [Self.bullets(["one", "two", "three"])])
    }

    @Test func numberedList() {
        let blocks = MarkdownBlock.parse("1. one\n2. two\n3. three")
        #expect(blocks == [Self.numbers(["one", "two", "three"])])
    }

    /// The live report: every item rendered `1.`, because a blank line between
    /// items gave each one a block of its own and the marker counts within its
    /// block.
    @Test func blankLinesBetweenItemsStayOneList() {
        let blocks = MarkdownBlock.parse("1. one\n\n2. two\n\n3. three")
        #expect(blocks == [Self.numbers(["one", "two", "three"])])
    }

    @Test func blankLinesBetweenBulletsStayOneList() {
        let blocks = MarkdownBlock.parse("- one\n\n- two")
        #expect(blocks == [Self.bullets(["one", "two"])])
    }

    /// The second suspect: a wrapped item's continuation line used to end the
    /// list and fall through to a paragraph.
    @Test func aWrappedItemKeepsItsContinuationLine() {
        let blocks = MarkdownBlock.parse("1. one that runs\n   past the end\n2. two")
        #expect(blocks == [Self.numbers(["one that runs past the end", "two"])])
    }

    @Test func aWrappedBulletKeepsItsContinuationLine() {
        let blocks = MarkdownBlock.parse("- one that runs\n  past the end\n- two")
        #expect(blocks == [Self.bullets(["one that runs past the end", "two"])])
    }

    @Test func aListKeepsTheNumberItStartedAt() {
        let blocks = MarkdownBlock.parse("3. three\n4. four")
        #expect(blocks == [Self.numbers(["three", "four"], from: 3)])
    }

    /// Only the first number survives: the marker counts from the start, so a
    /// list that repeats `1.` still renders 1, 2, 3.
    @Test func repeatedSourceNumbersStillCountUp() {
        let blocks = MarkdownBlock.parse("1. one\n1. two\n1. three")
        #expect(blocks == [Self.numbers(["one", "two", "three"])])
    }

    @Test func aBlankLineThenProseEndsTheList() {
        let blocks = MarkdownBlock.parse("1. one\n\nAfter the list.")
        #expect(blocks == [
            Self.numbers(["one"]),
            .paragraph("After the list."),
        ])
    }

    /// A marker change at one depth is one list, not two. An indented sublist
    /// routinely switches kind, and every item renders its own marker anyway.
    @Test func theOtherListKindContinuesTheList() {
        let blocks = MarkdownBlock.parse("1. one\n- bullet")
        #expect(blocks == [.list([
            .init(text: "one", number: 1),
            .init(text: "bullet"),
        ])])
    }

    @Test func aHeadingEndsTheList() {
        let blocks = MarkdownBlock.parse("1. one\n## Next")
        #expect(blocks == [
            Self.numbers(["one"]),
            .heading(level: 2, text: "Next"),
        ])
    }

    @Test func aFenceEndsTheList() {
        let blocks = MarkdownBlock.parse("1. one\n```\ncode\n```")
        #expect(blocks == [
            Self.numbers(["one"]),
            .codeBlock(language: nil, code: "code"),
        ])
    }

    @Test func consecutiveListItemsGroupIntoOneBlock() {
        let blocks = MarkdownBlock.parse("- a\n- b")
        #expect(blocks.count == 1)
        #expect(blocks == [Self.bullets(["a", "b"])])
    }

    @Test func listFollowedByParagraph() {
        let blocks = MarkdownBlock.parse("- a\n- b\n\nAfter the list.")
        #expect(blocks == [
            Self.bullets(["a", "b"]),
            .paragraph("After the list."),
        ])
    }

    @Test func anIndentedItemNestsOneLevel() {
        let blocks = MarkdownBlock.parse("- outer\n  - inner\n- back")
        #expect(blocks == [.list([
            .init(text: "outer"),
            .init(text: "inner", depth: 1),
            .init(text: "back"),
        ])])
    }

    /// Two, four and tab indents are all ordinary, so depth comes from the
    /// levels the source opened rather than from a fixed column width.
    @Test func depthComesFromTheLevelsOpenedNotTheColumnCount() {
        let blocks = MarkdownBlock.parse("- a\n    - b\n        - c\n    - d\n- e")
        #expect(blocks == [.list([
            .init(text: "a"),
            .init(text: "b", depth: 1),
            .init(text: "c", depth: 2),
            .init(text: "d", depth: 1),
            .init(text: "e"),
        ])])
    }

    @Test func aTabIndentNests() {
        let blocks = MarkdownBlock.parse("- a\n\t- b")
        #expect(blocks == [.list([.init(text: "a"), .init(text: "b", depth: 1)])])
    }

    /// Whatever the source indented it by, an item deeper than every open
    /// level opens exactly one.
    @Test func aFarIndentOpensOnlyOneLevel() {
        let blocks = MarkdownBlock.parse("- a\n            - b")
        #expect(blocks == [.list([.init(text: "a"), .init(text: "b", depth: 1)])])
    }

    @Test func aNumberedSublistCountsSeparatelyFromItsParent() {
        let blocks = MarkdownBlock.parse("1. one\n   1. inner one\n   2. inner two\n2. two")
        #expect(blocks == [.list([
            .init(text: "one", number: 1),
            .init(text: "inner one", depth: 1, number: 1),
            .init(text: "inner two", depth: 1, number: 2),
            .init(text: "two", number: 2),
        ])])
    }

    /// Reopening a sublist starts from its own source number rather than
    /// resuming the run that closed.
    @Test func aReopenedSublistRestartsItsCount() {
        let blocks = MarkdownBlock.parse("- a\n  1. x\n- b\n  1. y")
        #expect(blocks == [.list([
            .init(text: "a"),
            .init(text: "x", depth: 1, number: 1),
            .init(text: "b"),
            .init(text: "y", depth: 1, number: 1),
        ])])
    }

    @Test func aNestedListMixesKinds() {
        let blocks = MarkdownBlock.parse("1. step\n   - detail\n   - more\n2. next")
        #expect(blocks == [.list([
            .init(text: "step", number: 1),
            .init(text: "detail", depth: 1),
            .init(text: "more", depth: 1),
            .init(text: "next", number: 2),
        ])])
    }

    /// A nested item's own wrapped line still belongs to that item.
    @Test func aNestedItemKeepsItsContinuationLine() {
        let blocks = MarkdownBlock.parse("- outer\n  - inner that runs\n    past the end\n- back")
        #expect(blocks == [.list([
            .init(text: "outer"),
            .init(text: "inner that runs past the end", depth: 1),
            .init(text: "back"),
        ])])
    }

    @Test func horizontalRule() {
        let blocks = MarkdownBlock.parse("---")
        #expect(blocks == [.rule])
    }

    @Test func quote() {
        let blocks = MarkdownBlock.parse("> quoted text")
        #expect(blocks == [.quote("quoted text")])
    }

    @Test func inlineFormattingSurvivesIntoAttributedString() throws {
        let blocks = MarkdownBlock.parse("This is **bold** and *italic*.")
        guard case let .paragraph(text) = blocks.first else {
            Issue.record("expected a paragraph block")
            return
        }
        let attributed = try AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )
        let hasBold = attributed.runs.contains { run in
            run.inlinePresentationIntent?.contains(.stronglyEmphasized) ?? false
        }
        #expect(hasBold)
    }

    @Test func table() {
        let blocks = MarkdownBlock.parse("| a | b |\n| - | - |\n| 1 | 2 |")
        #expect(blocks == [.table(
            header: ["a", "b"],
            alignments: [.leading, .leading],
            rows: [["1", "2"]]
        )])
    }

    @Test func tableWithoutOuterPipesMatchesThePipedForm() {
        let bare = MarkdownBlock.parse("a | b\n--- | ---\n1 | 2")
        let piped = MarkdownBlock.parse("| a | b |\n| --- | --- |\n| 1 | 2 |")
        #expect(bare == piped)
    }

    @Test func tableAlignmentMarkers() {
        let blocks = MarkdownBlock.parse("| l | c | r | d |\n| :-- | :-: | --: | --- |\n| 1 | 2 | 3 | 4 |")
        #expect(blocks == [.table(
            header: ["l", "c", "r", "d"],
            alignments: [.leading, .center, .trailing, .leading],
            rows: [["1", "2", "3", "4"]]
        )])
    }

    /// `docs/ghostty-pin.md` uses an empty-header table as a key-value layout.
    @Test func tableWithEmptyHeaderCells() {
        let blocks = MarkdownBlock.parse("| | |\n|---|---|\n| Package | libghostty-spm |")
        #expect(blocks == [.table(
            header: ["", ""],
            alignments: [.leading, .leading],
            rows: [["Package", "libghostty-spm"]]
        )])
    }

    @Test func anAllEmptyHeaderIsNotWorthShowing() {
        #expect(MarkdownBlock.headerIsMeaningful(["a", "b"]))
        #expect(MarkdownBlock.headerIsMeaningful(["", "b"]))
        #expect(!MarkdownBlock.headerIsMeaningful(["", ""]))
        #expect(!MarkdownBlock.headerIsMeaningful([]))
    }

    @Test func tableRaggedRowsAreFittedToTheHeader() {
        let blocks = MarkdownBlock.parse("| a | b |\n| - | - |\n| 1 |\n| 1 | 2 | 3 |")
        #expect(blocks == [.table(
            header: ["a", "b"],
            alignments: [.leading, .leading],
            rows: [["1", ""], ["1", "2"]]
        )])
    }

    @Test func tableCellKeepsAnEscapedPipe() {
        let blocks = MarkdownBlock.parse("| a | b |\n| - | - |\n| x \\| y | z |")
        #expect(blocks == [.table(
            header: ["a", "b"],
            alignments: [.leading, .leading],
            rows: [["x | y", "z"]]
        )])
    }

    @Test func pipeInProseStaysAParagraph() {
        let text = "Run a | b to pipe.\nThe second line has no delimiter row."
        #expect(MarkdownBlock.parse(text) == [.paragraph(text)])
    }

    @Test func delimiterRowDisagreeingWithTheHeaderIsNotATable() {
        let text = "| a | b |\n| --- |"
        #expect(MarkdownBlock.parse(text) == [.paragraph(text)])
    }

    @Test func tableWithNoBodyRows() {
        let blocks = MarkdownBlock.parse("| a | b |\n| - | - |")
        #expect(blocks == [.table(
            header: ["a", "b"],
            alignments: [.leading, .leading],
            rows: []
        )])
    }

    @Test func tableThenParagraph() {
        let blocks = MarkdownBlock.parse("| a |\n| - |\n| 1 |\n\nAfter.")
        #expect(blocks == [
            .table(header: ["a"], alignments: [.leading], rows: [["1"]]),
            .paragraph("After.")
        ])
    }

    @Test func paragraphThenTable() {
        let blocks = MarkdownBlock.parse("Before.\n| a |\n| - |\n| 1 |")
        #expect(blocks == [
            .paragraph("Before."),
            .table(header: ["a"], alignments: [.leading], rows: [["1"]])
        ])
    }
}
