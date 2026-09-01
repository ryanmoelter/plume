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

    @Test func tableDegradesToParagraph() {
        let table = "| a | b |\n| - | - |\n| 1 | 2 |"
        let blocks = MarkdownBlock.parse(table)
        // Tables aren't a supported block kind: keep the raw lines as a
        // paragraph rather than mangling or dropping them.
        #expect(blocks == [.paragraph(table)])
    }
}
