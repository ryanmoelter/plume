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

    @Test func h6OffsetsComeFromTheSourceNotTheUppercase() {
        let pieces = Fixtures.pieces("###### straße ok")
        let piece = pieces[0]
        let markdownResult = ChatSelectionSerializer.markdown(of: pieces, selection: Fixtures.selection(piece, 0..<6))
        #expect(markdownResult == "###### straße")
        let plain = ChatSelectionSerializer.plainText(of: pieces, selection: Fixtures.selection(piece, 0..<6))
        #expect(plain == "STRASSE")
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
        #expect(partial == "| ty |\n| --: |\n| apple | 3 |\n| pe |")
    }

    @Test func aToolCallPieceInTheRangeIsSkipped() {
        let call = ToolCall(id: "t", name: "Read", summary: ToolCallSummary(name: "Read", detail: "f"), input: .json("{}"))
        let message = ChatMessage(
            id: "m", role: .assistant,
            blocks: [.markdown("before"), .toolCall(call), .markdown("after")],
            timestamp: nil, isLive: false
        )
        let pieces = ChatPieceSplitter.pieces(
            for: [message], status: .awaitingReply, hiddenToolUseIDs: [], dimensions: Dimensions(bodySize: 13)
        )
        #expect(pieces.count == 3)
        let selection = Fixtures.selection(from: (pieces[0], 2), to: (pieces[2], 3))
        #expect(ChatSelectionSerializer.markdown(of: pieces, selection: selection) == "fore\n\naft")
        #expect(ChatSelectionSerializer.plainText(of: pieces, selection: selection) == "fore\n\naft")
    }

    @Test func plainTextKeepsListMarkersAndTabsBetweenCells() {
        let pieces = Fixtures.pieces("Intro\n\n- one\n- two\n\n| a | b |\n|---|---|\n| 1 | 2 |")
        let result = ChatSelectionSerializer.plainText(of: pieces, selection: Fixtures.everything(pieces))
        #expect(result == "Intro\n\n\u{2022} one\n\u{2022} two\n\na\tb\n1\t2")
    }

    @Test func plainTextStripsMarkup() {
        let pieces = Fixtures.pieces("a **bold** [link](https://x.y) `code`")
        let piece = pieces[0]
        let result = ChatSelectionSerializer.plainText(
            of: pieces, selection: Fixtures.selection(piece, 0..<ChatSelectableText.length(of: piece))
        )
        #expect(result == "a bold link code")
    }

    @Test func rtfCarriesTraitsAndLinksButNoColors() throws {
        let pieces = Fixtures.pieces("plain **bold** *it* `mono` [site](https://example.com)")
        let piece = pieces[0]
        let data = try #require(ChatSelectionSerializer.rtf(
            of: pieces, selection: Fixtures.selection(piece, 0..<ChatSelectableText.length(of: piece))
        ))
        let read = try #require(NSAttributedString(rtf: data, documentAttributes: nil))
        #expect(read.string == "plain bold it mono site")

        var sawBold = false
        var sawLink = false
        var sawMono = false
        var sawColor = false
        read.enumerateAttributes(in: NSRange(location: 0, length: read.length)) { attributes, _, _ in
            if let font = attributes[.font] as? NSFont {
                sawBold = sawBold || font.fontDescriptor.symbolicTraits.contains(.bold)
                sawMono = sawMono || font.fontDescriptor.symbolicTraits.contains(.monoSpace)
            }
            sawLink = sawLink || attributes[.link] != nil
            sawColor = sawColor || attributes[.foregroundColor] != nil || attributes[.backgroundColor] != nil
        }
        #expect(sawBold)
        #expect(sawMono)
        #expect(sawLink)
        #expect(!sawColor)
    }

    @Test func aFiveHundredPieceSelectionSerializes() {
        let source = (0..<500).map { "Paragraph \($0) with **bold** text." }.joined(separator: "\n\n")
        let pieces = Fixtures.pieces(source)
        #expect(pieces.count == 500)
        let selection = Fixtures.selection(from: (pieces[0], 3), to: (pieces[499], 11))
        let markdown = ChatSelectionSerializer.markdown(of: pieces, selection: selection)
        let plain = ChatSelectionSerializer.plainText(of: pieces, selection: selection)
        #expect(markdown.hasPrefix("agraph 0 with **bold** text."))
        #expect(plain.hasSuffix("Paragraph 4"))
        #expect(plain.components(separatedBy: "\n\n").count == 500)
        #expect(ChatSelectionSerializer.rtf(of: pieces, selection: selection) != nil)
    }

    @Test func aReversedSelectionSerializesLikeAForwardOne() {
        let pieces = Fixtures.pieces("alpha\n\nbeta\n\ngamma")
        let forward = Fixtures.selection(from: (pieces[0], 2), to: (pieces[2], 3))
        let backward = ChatSelection(anchor: forward.focus, focus: forward.anchor)
        #expect(
            ChatSelectionSerializer.markdown(of: pieces, selection: forward)
                == ChatSelectionSerializer.markdown(of: pieces, selection: backward)
        )
        #expect(ChatSelectionSerializer.markdown(of: pieces, selection: forward) == "pha\n\nbeta\n\ngam")
    }
}
