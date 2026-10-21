import Foundation
import Testing
@testable import Plume

@MainActor
struct ChatSelectionTests {
    init() { MarkdownCache.reset() }

    private func position(_ id: String, _ offset: Int) -> ChatTextPosition {
        ChatTextPosition(pieceID: id, offset: offset)
    }

    private let order = ChatPieceOrder(["a", "b", "c"])

    @Test func boundsOrderAcrossPieces() {
        let forward = ChatSelection(anchor: position("a", 4), focus: position("c", 1))
        let backward = ChatSelection(anchor: position("c", 1), focus: position("a", 4))
        #expect(forward.bounds(in: order) == ChatSelection.Bounds(start: position("a", 4), end: position("c", 1)))
        #expect(backward.bounds(in: order) == forward.bounds(in: order))
    }

    @Test func boundsOrderReversedOffsetsInOnePiece() {
        let selection = ChatSelection(anchor: position("b", 9), focus: position("b", 2))
        #expect(selection.bounds(in: order) == ChatSelection.Bounds(start: position("b", 2), end: position("b", 9)))
    }

    @Test func boundsAreNilForAnUnknownPiece() {
        #expect(ChatSelection(anchor: position("z", 0), focus: position("a", 0)).bounds(in: order) == nil)
    }

    @Test func extendingKeepsTheAnchor() {
        let selection = ChatSelection(anchor: position("a", 2), focus: position("a", 5))
        let extended = selection.extended(to: position("c", 3))
        #expect(extended.anchor == position("a", 2))
        #expect(extended.focus == position("c", 3))
        #expect(!extended.isCollapsed)
    }

    @Test func expandToPieceCoversItsLength() {
        let selection = ChatSelection.expandToPiece("b", length: 12)
        #expect(selection.anchor == position("b", 0))
        #expect(selection.focus == position("b", 12))
    }

    private func word(_ markdown: String, at offset: Int) -> String? {
        let piece = ChatSelectionFixtures.pieces(markdown)[0]
        let text = ChatSelectableText(piece: piece)
        guard let selection = ChatSelection.expandToWord(at: position(piece.id, offset), in: text),
              let bounds = selection.bounds(in: ChatPieceOrder([piece.id])) else { return nil }
        return (text.plainText as NSString).substring(
            with: NSRange(location: bounds.start.offset, length: bounds.end.offset - bounds.start.offset)
        )
    }

    @Test func wordExpansionStopsAtPunctuation() {
        #expect(word("Hello, world!", at: 2) == "Hello")
        #expect(word("Hello, world!", at: 8) == "world")
    }

    @Test func wordExpansionOnASeparatorSelectsTheGap() {
        #expect(word("one   two", at: 4) == "   ")
    }

    @Test func wordExpansionUsesTheRenderedTextNotTheMarkup() {
        #expect(word("say **loud** now", at: 6) == "loud")
    }

    @Test func wordExpansionSegmentsCJK() {
        let result = word("今日は天気です", at: 0)
        #expect(result != nil)
        #expect(result != "今日は天気です")
    }

    @Test func wordExpansionNeverSpansListItems() {
        let piece = ChatPiece(
            id: "p", messageID: "m", role: .assistant,
            content: .listSegment(ListSegment(items: [.init(text: "one"), .init(text: "two")])),
            wash: .none
        )
        let text = ChatSelectableText(piece: piece)
        #expect(text.wordRange(at: 1) == 0..<3)
        #expect(text.wordRange(at: 4) == 3..<6)
    }

    private let lengths = ["a": 10, "b": 5, "c": 8, "d": 0]

    private func clamp(_ selection: ChatSelection, from old: [String], to new: [String]) -> ChatSelection? {
        selection.clamped(from: old, toIDs: new) { lengths[$0] ?? 0 }
    }

    @Test func aShrunkPieceClampsTheOffset() {
        let selection = ChatSelection(anchor: position("a", 2), focus: position("b", 50))
        let clamped = clamp(selection, from: ["a", "b"], to: ["a", "b"])
        #expect(clamped == ChatSelection(anchor: position("a", 2), focus: position("b", 5)))
    }

    @Test func aVanishedEndMovesToTheNextSurvivorsStart() {
        let selection = ChatSelection(anchor: position("a", 2), focus: position("b", 3))
        let clamped = clamp(selection, from: ["a", "b", "c"], to: ["a", "c"])
        #expect(clamped == ChatSelection(anchor: position("a", 2), focus: position("c", 0)))
    }

    @Test func aVanishedEndWithNoLaterSurvivorMovesToTheEarlierOnesEnd() {
        let selection = ChatSelection(anchor: position("a", 2), focus: position("c", 3))
        let clamped = clamp(selection, from: ["a", "b", "c"], to: ["a", "b"])
        #expect(clamped == ChatSelection(anchor: position("a", 2), focus: position("b", 5)))
    }

    @Test func aPieceWithNothingSelectableCountsAsVanished() {
        let selection = ChatSelection(anchor: position("a", 2), focus: position("d", 0))
        let clamped = clamp(selection, from: ["a", "d", "c"], to: ["a", "d", "c"])
        #expect(clamped == ChatSelection(anchor: position("a", 2), focus: position("c", 0)))
    }

    @Test func nothingSurvivingClearsTheSelection() {
        let selection = ChatSelection(anchor: position("a", 2), focus: position("b", 3))
        #expect(clamp(selection, from: ["a", "b"], to: []) == nil)
    }

    @Test func clampingFromPiecesUsesTheirSelectableLength() {
        let pieces = ChatSelectionFixtures.pieces("Short.")
        let selection = ChatSelection(anchor: position(pieces[0].id, 0), focus: position(pieces[0].id, 99))
        #expect(selection.clamped(from: [pieces[0].id], to: pieces)?.focus.offset == 6)
    }
}
