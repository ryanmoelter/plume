import Foundation
import Testing
@testable import Plume

/// Round-tripping markdown through the composer's attributed-string model.
///
/// The policy is non-negotiable: nothing here escapes a literal markdown
/// character, since the message goes to an LLM rather than a renderer. A
/// "formatting" case must come back byte-for-byte; a "literal" case only has
/// to keep its telltale substring intact somewhere in the built text.
struct ComposerDocumentTests {
    private static let style = ComposerTextStyle(bodySize: 14)

    private struct RoundTripCase: CustomTestStringConvertible {
        enum Expectation {
            /// `markdown(attributedString(x)) == x`.
            case exact
            /// The literal substring survives unescaped, wherever it lands.
            case containsLiteral(String)
        }

        let markdown: String
        let expectation: Expectation
        var testDescription: String { markdown }

        static func exact(_ markdown: String) -> RoundTripCase {
            RoundTripCase(markdown: markdown, expectation: .exact)
        }

        static func literal(_ markdown: String, contains substring: String) -> RoundTripCase {
            RoundTripCase(markdown: markdown, expectation: .containsLiteral(substring))
        }
    }

    private static let corpus: [RoundTripCase] = [
        .exact("Just a plain paragraph."),
        .literal("foo_bar stays untouched.", contains: "foo_bar"),
        .literal("~/.claude/*.json is a literal path.", contains: "~/.claude/*.json"),
        .literal("a * b is not emphasis.", contains: "a * b"),
        .literal("A literal backslash: C:\\path", contains: "C:\\path"),
        .exact("This is **bold** text."),
        .exact("This is *italic* text."),
        .exact("This is a *phrase with **bold inside it** right here* line."),
        .exact("``a`b``"),
        .exact("A [link](https://example.com)."),
        .exact("# Heading 1"),
        .exact("## Heading 2"),
        .exact("### Heading 3"),
        .exact("#### Heading 4"),
        .exact("##### Heading 5"),
        .exact("###### Heading 6"),
        .exact("- one\n  - two\n    - three"),
        .exact("1. one\n  - two\n    1. three"),
        .exact("> line one\n> line two"),
        .exact("```swift\nlet x = 1\n```"),
        .exact("````md\n```\nnested\n```\n````"),
        .exact("---"),
        .exact("First paragraph.\n\nSecond paragraph."),
        .exact(""),
    ]

    @Test(arguments: corpus)
    private func roundTrips(_ testCase: RoundTripCase) {
        let attributed = ComposerDocument.attributedString(markdown: testCase.markdown, style: Self.style)
        let result = ComposerDocument.markdown(from: attributed)
        switch testCase.expectation {
        case .exact:
            #expect(result == testCase.markdown)
        case let .containsLiteral(substring):
            #expect(result.contains(substring))
        }
    }

    @Test func aTableStaysVerbatim() {
        let markdown = "| a | b |\n| --- | --- |\n| 1 | 2 |"
        let attributed = ComposerDocument.attributedString(markdown: markdown, style: Self.style)
        #expect(ComposerDocument.markdown(from: attributed) == markdown)
    }

    /// `MarkdownBlock.parseWithSources` drops a paragraph's own trailing
    /// blank line from its source, so a trailing newline never reaches the
    /// composer's model to round-trip back out — the documented
    /// non-bijection, not a bug.
    @Test func aTrailingNewlineIsNotPreserved() {
        let attributed = ComposerDocument.attributedString(markdown: "Hello\n", style: Self.style)
        #expect(ComposerDocument.markdown(from: attributed) == "Hello")
    }

    @Test func twoSameLanguageCodeBlocksStaySeparate() {
        let markdown = "```swift\nfirst\n```\n\n```swift\nsecond\n```"
        let attributed = ComposerDocument.attributedString(markdown: markdown, style: Self.style)
        #expect(ComposerDocument.markdown(from: attributed) == markdown)

        guard
            let first = attributed.attribute(.plumeBlock, at: 0, effectiveRange: nil) as? ComposerBlockKind,
            let second = attributed.attribute(.plumeBlock, at: attributed.length - 1, effectiveRange: nil) as? ComposerBlockKind
        else {
            Issue.record("expected codeBlock kinds at both ends")
            return
        }
        #expect(first.kind == .codeBlock(language: "swift"))
        #expect(second.kind == .codeBlock(language: "swift"))
        #expect(first.blockID != second.blockID)
    }

    /// A verbatim block has no editing story, but its characters are still
    /// editable text: what serializes is what the paragraphs now say, not the
    /// source they were parsed from.
    @Test func editedVerbatimBlockSerializesWhatIsOnScreen() throws {
        let markdown = "| a | b |\n| --- | --- |\n| 1 | 2 |"
        let attributed = NSMutableAttributedString(
            attributedString: ComposerDocument.attributedString(markdown: markdown, style: Self.style)
        )
        // Typing carries the paragraph's own kind, `blockID` included, which
        // is what keeps the table one block.
        let kind = try #require(attributed.attribute(.plumeBlock, at: 0, effectiveRange: nil) as? ComposerBlockKind)
        attributed.replaceCharacters(
            in: NSRange(location: 0, length: 0),
            with: NSAttributedString(string: "Z", attributes: Self.style.attributes(for: kind))
        )

        #expect(ComposerDocument.markdown(from: attributed) == "Z\(markdown)")
    }

    /// Two thematic breaks read as two blocks, which only their `blockID`
    /// distinguishes — without one they compare equal and merge into a single
    /// rule on the way back out.
    @Test func adjacentRulesStayTwoBlocks() {
        let markdown = "---\n\n---"
        let attributed = ComposerDocument.attributedString(markdown: markdown, style: Self.style)
        #expect(ComposerDocument.markdown(from: attributed) == markdown)
    }

    @Test func emptyHeadingIsNotSendable() {
        let attributed = ComposerDocument.attributedString(markdown: "# ", style: Self.style)
        #expect(!ComposerDocument.plainTextIsSendable(attributed))
    }

    @Test func whitespaceOnlyIsNotSendable() {
        #expect(!ComposerDocument.plainTextIsSendable(NSAttributedString(string: "  \n")))
    }

    @Test func nonWhitespaceIsSendable() {
        let attributed = ComposerDocument.attributedString(markdown: "x", style: Self.style)
        #expect(ComposerDocument.plainTextIsSendable(attributed))
    }
}
