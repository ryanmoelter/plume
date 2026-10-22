import Foundation
import Testing
@testable import Plume

@MainActor
struct ChatSelectableTextTests {
    init() { MarkdownCache.reset() }

    @Test func aParagraphIsOneFragmentOfTheRevealLength() throws {
        let pieces = ChatSelectionFixtures.pieces("Hello **bold** world")
        let text = ChatSelectableText(piece: pieces[0])
        #expect(text.fragments.count == 1)
        #expect(text.fragments[0].start == 0)
        #expect(text.length == pieces[0].revealLength)
        #expect(text.plainText == "Hello bold world")
    }

    @Test func nestedListFragmentsStartWhereTheViewStartsEachItem() {
        let items = [
            MarkdownBlock.ListItem(text: "one **bold**", depth: 0, number: nil),
            MarkdownBlock.ListItem(text: "two", depth: 1, number: nil),
            MarkdownBlock.ListItem(text: "three `code`", depth: 2, number: 7),
            MarkdownBlock.ListItem(text: "four", depth: 0, number: 8),
        ]
        let piece = ChatPiece(
            id: "p", messageID: "m", role: .assistant,
            content: .listSegment(ListSegment(items: items)), wash: .none
        )
        let fragments = ChatSelectableText(piece: piece).fragments
        var expected = 0
        for (fragment, item) in zip(fragments, items) {
            #expect(fragment.start == expected)
            expected += ChatReveal.length(of: item.text)
            #expect(fragment.length == ChatReveal.length(of: item.text))
        }
        #expect(fragments.last?.end == ChatReveal.length(of: piece.content))
        #expect(fragments[0].kind == .listItem(depth: 0, marker: "\u{2022}", ordinal: nil))
        #expect(fragments[1].kind == .listItem(depth: 1, marker: "\u{25E6}", ordinal: nil))
        #expect(fragments[2].kind == .listItem(depth: 2, marker: "7.", ordinal: 7))
    }

    @Test func raggedTableFragmentsMatchTheRevealCellOffsets() {
        let header = ["A", "B", "C"]
        let rows = [["1"], ["22", "x **y**"], ["333", "", "z", "extra"]]
        let piece = ChatPiece(
            id: "p", messageID: "m", role: .assistant,
            content: .markdown(.table(header: header, alignments: [], rows: rows), index: 0),
            wash: .none
        )
        let fragments = ChatSelectableText(piece: piece).fragments
        let offsets = ChatReveal.tableCellOffsets(header: header, rows: rows)
        #expect(fragments.map(\.start) == offsets)
        #expect(fragments.count == 16)
        #expect(fragments.last?.end == ChatReveal.length(of: piece.content))
        #expect(fragments[0].kind == .tableCell(row: 0, column: 0, isHeader: true))
        #expect(fragments[5].kind == .tableCell(row: 1, column: 1, isHeader: false))
    }

    @Test func aTableWithAnEmptyHeaderHasNoHeaderCells() {
        let piece = ChatPiece(
            id: "p", messageID: "m", role: .assistant,
            content: .markdown(.table(header: ["", ""], alignments: [], rows: [["k", "v"]]), index: 0),
            wash: .none
        )
        let fragments = ChatSelectableText(piece: piece).fragments
        #expect(fragments.map(\.start) == [0, 1])
        #expect(fragments[0].kind == .tableCell(row: 0, column: 0, isHeader: false))
    }

    @Test func codeUsesTheRawCodeAndMermaidHasNoFragments() {
        let code = ChatSelectableText(piece: ChatSelectionFixtures.pieces("```swift\nlet a = 1\n```")[0])
        #expect(code.fragments.count == 1)
        #expect(code.length == "let a = 1".utf16.count)
        #expect(code.fragments[0].kind == .code(language: "swift", code: "let a = 1"))

        let mermaid = ChatSelectableText(piece: ChatSelectionFixtures.pieces("```mermaid\ngraph TD\n```")[0])
        #expect(mermaid.fragments.isEmpty)
    }

    @Test func headingKeepsTheSourceLengthWhenUppercased() {
        let piece = ChatSelectionFixtures.pieces("###### straße")[0]
        let text = ChatSelectableText(piece: piece)
        #expect(text.length == "straße".utf16.count)
        #expect(text.fragments[0].kind == .heading(level: 6))
    }

    @Test func nonMarkdownPiecesHaveNoFragments() {
        let call = ToolCall(id: "t", name: "Read", summary: ToolCallSummary(name: "Read", detail: "f"), input: .json("{}"))
        let piece = ChatPiece(
            id: "p", messageID: "m", role: .assistant, content: .toolCall(call, isPending: false), wash: .none
        )
        #expect(ChatSelectableText(piece: piece).fragments.isEmpty)
    }

    @Test func everyPieceOfAMessageLaysEndToEndAlongTheReveal() {
        let pieces = ChatSelectionFixtures.pieces("# Title\n\nBody *text*.\n\n- a\n- b\n\n| x | y |\n|---|---|\n| 1 | 2 |")
        for piece in pieces {
            #expect(ChatSelectableText.length(of: piece) == piece.revealLength)
        }
    }

    @Test func fragmentIndexFindsTheFragmentAndBoundariesBelongToTheLaterOne() {
        let piece = ChatPiece(
            id: "p", messageID: "m", role: .assistant,
            content: .listSegment(ListSegment(items: [
                .init(text: "ab"), .init(text: "cd"),
            ])),
            wash: .none
        )
        let text = ChatSelectableText(piece: piece)
        #expect(text.fragmentIndex(containing: 0) == 0)
        #expect(text.fragmentIndex(containing: 1) == 0)
        #expect(text.fragmentIndex(containing: 2) == 1)
        #expect(text.fragmentIndex(containing: 4) == 1)
        #expect(text.fragmentIndex(containing: 5) == nil)
    }

    @Test func sliceCutsByUTF16AndKeepsAttributes() {
        let source = MarkdownCache.inline("a **b😀c** d")
        let slice = source.slice(utf16: 2..<6)
        #expect(String(slice.characters) == "b😀c")
        #expect(slice.runs.first?.inlinePresentationIntent == .stronglyEmphasized)
    }
}
