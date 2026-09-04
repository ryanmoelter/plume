import Foundation
import Testing
@testable import Plume

struct MarkdownBlockTests {
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

    @Test func headingLevels() {
        for level in 1...6 {
            let hashes = String(repeating: "#", count: level)
            let blocks = MarkdownBlock.parse("\(hashes) Title")
            #expect(blocks == [.heading(level: level, text: "Title")])
        }
    }

    @Test func bulletList() {
        let blocks = MarkdownBlock.parse("- one\n- two\n- three")
        #expect(blocks == [.bulletList(["one", "two", "three"])])
    }

    @Test func numberedList() {
        let blocks = MarkdownBlock.parse("1. one\n2. two\n3. three")
        #expect(blocks == [.numberedList(["one", "two", "three"])])
    }

    @Test func consecutiveListItemsGroupIntoOneBlock() {
        let blocks = MarkdownBlock.parse("- a\n- b")
        #expect(blocks.count == 1)
        #expect(blocks == [.bulletList(["a", "b"])])
    }

    @Test func listFollowedByParagraph() {
        let blocks = MarkdownBlock.parse("- a\n- b\n\nAfter the list.")
        #expect(blocks == [
            .bulletList(["a", "b"]),
            .paragraph("After the list."),
        ])
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
