import AppKit
import Foundation
import Testing
@testable import Plume

@MainActor
struct ChatSelectionSerializerTests {
    init() { MarkdownCache.reset() }

    private typealias Fixtures = ChatSelectionFixtures

    private func markdown(_ source: String, selecting needle: String) -> String {
        let pieces = Fixtures.pieces(source)
        let piece = pieces[0]
        return ChatSelectionSerializer.markdown(
            of: pieces,
            selection: Fixtures.selection(piece, Fixtures.range(of: needle, in: piece))
        )
    }

    @Test func aWholePieceUsesItsCopySource() {
        let pieces = Fixtures.pieces("Some   **spaced**   text")
        let result = ChatSelectionSerializer.markdown(of: pieces, selection: Fixtures.everything(pieces))
        #expect(result == "Some   **spaced**   text")
    }

    @Test func aPromptCopiesAsOneBlockquote() {
        let prompt = Fixtures.pieces("Fix the build.\n\n- first\n- second", messageID: "u", role: .user)
        let reply = Fixtures.pieces("Done.", messageID: "a")
        let pieces = prompt + reply
        let result = ChatSelectionSerializer.markdown(of: pieces, selection: Fixtures.everything(pieces))
        #expect(result == "> Fix the build.\n>\n> - first\n> - second\n\nDone.")
        let plain = ChatSelectionSerializer.plainText(of: pieces, selection: Fixtures.everything(pieces))
        #expect(!plain.contains(">"))
    }

    @Test func aPromptAloneCopiesWithoutAQuote() {
        let prompt = Fixtures.pieces("Fix the build.\n\n- first\n- second", messageID: "u", role: .user)
        let result = ChatSelectionSerializer.markdown(of: prompt, selection: Fixtures.everything(prompt))
        #expect(result == "Fix the build.\n\n- first\n- second")
    }

    @Test func partialBoldKeepsItsMarkers() {
        #expect(markdown("a **bold** word", selecting: "ol") == "**ol**")
    }

    @Test func partialSelectionAcrossStylesWritesEachRun() {
        #expect(markdown("x *it* and ~~gone~~ y", selecting: "t and go") == "*t* and ~~go~~")
    }

    @Test func partialLinkKeepsItsURL() {
        #expect(markdown("see [the docs](https://example.com/a) now", selecting: "docs") == "[docs](https://example.com/a)")
    }

    @Test func codeContainingBackticksGetsALongerFence() {
        #expect(markdown("run ``a`b`` now", selecting: "a`b") == "``a`b``")
    }

    @Test func literalMarkupCharactersAreEscaped() {
        let pieces = Fixtures.pieces("a \\*star\\* and snake\\_case [x]")
        let piece = pieces[0]
        let range = Fixtures.range(of: "*star* and snake_case [x]", in: piece)
        let result = ChatSelectionSerializer.markdown(of: pieces, selection: Fixtures.selection(piece, range))
        #expect(result == "\\*star\\* and snake\\_case \\[x\\]")
    }

    @Test func whitespaceStaysOutsideDelimiters() {
        #expect(markdown("a **bold text** b", selecting: "ld te") == "**ld te**")
        #expect(markdown("a **bold text** b", selecting: "ld ") == "**ld** ")
    }

    @Test func aListItemFromItsStartKeepsMarkerAndIndent() {
        let items = [
            MarkdownBlock.ListItem(text: "outer", depth: 0, number: nil),
            MarkdownBlock.ListItem(text: "inner **b**old", depth: 1, number: nil),
            MarkdownBlock.ListItem(text: "numbered", depth: 1, number: 3),
        ]
        let piece = ChatPiece(
            id: "p", messageID: "m", role: .assistant,
            content: .listSegment(ListSegment(items: items)), wash: .none, copySource: "full"
        )
        let start = ChatSelectableText(piece: piece).fragments[1].start
        let result = ChatSelectionSerializer.markdown(of: [piece], selection: Fixtures.selection(piece, (start + 1)..<(start + 7)))
        #expect(result == "nner **b**")

        let fromStart = ChatSelectionSerializer.markdown(of: [piece], selection: Fixtures.selection(piece, start..<(start + 7)))
        #expect(fromStart == "  - inner **b**")

        let numbered = ChatSelectableText(piece: piece).fragments[2]
        let third = ChatSelectionSerializer.markdown(of: [piece], selection: Fixtures.selection(piece, numbered.start..<(numbered.start + 3)))
        #expect(third == "  3. num")
    }

    @Test func aPartialQuotePrefixesEveryLine() {
        let pieces = Fixtures.pieces("> first line\n> second line")
        let piece = pieces[0]
        let result = ChatSelectionSerializer.markdown(of: pieces, selection: Fixtures.selection(piece, 0..<14))
        #expect(result == "> first line\n> sec")
    }

    @Test func aPartialHeadingKeepsItsHashes() {
        #expect(markdown("## Big title", selecting: "Big") == "## Big")
        #expect(markdown("## Big title", selecting: "itl") == "itl")
    }

    @Test func anH6CopiesInItsSourceCase() {
        let pieces = Fixtures.pieces("###### straße ok")
        let piece = pieces[0]
        let markdownResult = ChatSelectionSerializer.markdown(of: pieces, selection: Fixtures.selection(piece, 0..<6))
        #expect(markdownResult == "###### straße")
        let plain = ChatSelectionSerializer.plainText(of: pieces, selection: Fixtures.selection(piece, 0..<6))
        #expect(plain == "straße")
    }

    @Test func aCodeSliceIsFencedWithItsLanguage() {
        let pieces = Fixtures.pieces("```swift\nlet a = 1\nlet b = 2\n```")
        let piece = pieces[0]
        let result = ChatSelectionSerializer.markdown(of: pieces, selection: Fixtures.selection(piece, 4..<13))
        #expect(result == "```swift\na = 1\nlet\n```")
    }

    @Test func aCodeSliceContainingAFenceUsesALongerOne() {
        let code = "before\n```\ninner\n```"
        let piece = ChatPiece(
            id: "p", messageID: "m", role: .assistant,
            content: .codeSegment(CodeSegment(language: "md", code: code)), wash: .none, copySource: "whole"
        )
        let result = ChatSelectionSerializer.markdown(of: [piece], selection: Fixtures.selection(piece, 1..<code.utf16.count))
        #expect(result == "````md\nefore\n```\ninner\n```\n````")
    }

    @Test func aTableSliceWritesRowsAndTheHeaderSeparator() {
        let pieces = Fixtures.pieces("| Name | Qty |\n|:--|--:|\n| apple | 3 |\n| pear | 10 |")
        let piece = pieces[0]
        let text = ChatSelectableText(piece: piece)
        let all = ChatSelectionSerializer.markdown(of: pieces, selection: Fixtures.selection(piece, 0..<text.length))
        #expect(all == "| Name | Qty |\n|:--|--:|\n| apple | 3 |\n| pear | 10 |")

        let partial = ChatSelectionSerializer.markdown(
            of: pieces,
            selection: Fixtures.selection(piece, text.fragments[1].start + 1..<text.fragments[4].start + 2)
        )
        #expect(partial == "| Name | Qty |\n| --- | --: |\n| apple | 3 |\n| pear | 10 |")

        let body = ChatSelectionSerializer.markdown(
            of: pieces,
            selection: Fixtures.selection(piece, text.fragments[3].start..<text.fragments[3].start + 1)
        )
        #expect(body == "| Name | Qty |\n| --- | --: |\n| apple | 3 |")
    }

    @Test func aHeaderlessTableSliceGetsAnEmptyHeader() {
        let table = MarkdownBlock.table(header: ["", ""], alignments: [.leading, .center], rows: [["a", "b"], ["c", "d"]])
        let piece = ChatPiece(
            id: "p", messageID: "m", role: .assistant,
            content: .markdown(table, index: 0), wash: .none, copySource: "full"
        )
        let start = ChatSelectableText(piece: piece).fragments[3].start
        let result = ChatSelectionSerializer.markdown(of: [piece], selection: Fixtures.selection(piece, start..<start + 1))
        #expect(result == "|  |  |\n| --- | :-: |\n| c | d |")
    }

    @Test func tablePipesInCellsAreEscaped() {
        let table = MarkdownBlock.table(header: ["a"], alignments: [.leading], rows: [["x | y"]])
        let piece = ChatPiece(
            id: "p", messageID: "m", role: .assistant,
            content: .markdown(table, index: 0), wash: .none, copySource: "full"
        )
        let start = ChatSelectableText(piece: piece).fragments[1].start
        let result = ChatSelectionSerializer.markdown(of: [piece], selection: Fixtures.selection(piece, start..<start + 2))
        #expect(result == "| a |\n| --- |\n| x \\| y |")
    }

    @Test func listsOfDifferentKindsAreSeparatedByABlankLine() {
        let pieces = Fixtures.pieces("- banana item\n\n1. first step")
        let result = ChatSelectionSerializer.markdown(of: pieces, selection: Fixtures.everything(pieces))
        #expect(result == "- banana item\n\n1. first step")
        let partial = ChatSelectionSerializer.markdown(of: pieces, selection: Fixtures.selection(from: (pieces[0], 0), to: (pieces[1], 4)))
        #expect(partial.contains("\n\n"))
    }

    @Test func itemsOfOneListJoinWithASingleNewline() {
        let pieces = Fixtures.pieces("- one\n- two\n- three")
        #expect(pieces.count == 3)
        let result = ChatSelectionSerializer.markdown(of: pieces, selection: Fixtures.everything(pieces))
        #expect(result == "- one\n- two\n- three")
    }

    @Test func listsFromDifferentMessagesAreSeparated() {
        let first = Fixtures.pieces("- a\n- b", messageID: "m1")
        let second = Fixtures.pieces("- c\n- d", messageID: "m2")
        let pieces = first + second
        let result = ChatSelectionSerializer.markdown(of: pieces, selection: Fixtures.everything(pieces))
        #expect(result == "- a\n- b\n\n- c\n- d")
    }

    @Test func partialTextEscapesMoreMarkup() {
        #expect(markdown("a \\~tilde \\<tag> x", selecting: "~tilde <tag>") == "\\~tilde \\<tag>")
    }

    @Test func partialTextEscapesLeadingBlockMarkers() {
        #expect(markdown("x \\# not heading here", selecting: "# not") == "\\# not")
        #expect(markdown("x \\> quoted here", selecting: "> quoted") == "\\> quoted")
        #expect(markdown("x \\- dash here", selecting: "- dash") == "\\- dash")
        #expect(markdown("x \\+ plus here", selecting: "+ plus") == "\\+ plus")
        #expect(markdown("x 1\\. one here", selecting: "1. one") == "1\\. one")
        #expect(markdown("x 2\\) two here", selecting: "2) two") == "2\\) two")
        #expect(markdown("x 3.5 here", selecting: "3.5 he") == "3.5 he")
    }

    @Test func linkDestinationsWithParenthesesUseAngleBrackets() {
        #expect(markdown("[doc](<https://e.com/a(1)>) end", selecting: "doc") == "[doc](<https://e.com/a(1)>)")
        #expect(markdown("[doc](https://e.com/a%20b) end", selecting: "doc") == "[doc](https://e.com/a%20b)")
    }
}
