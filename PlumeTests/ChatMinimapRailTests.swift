import CoreGraphics
import Foundation
import Testing
@testable import Plume

/// The collapsed rail's drawn geometry: prompts as fixed full-width bars,
/// responses as weighted half-width bars, stacked with the entry spacing, and
/// a click mapped back to the entry whose row it lands in.
@MainActor
struct ChatMinimapRailTests {
    private func entry(_ id: String, _ kind: ChatOutline.Kind, weight: CGFloat, pieces: Set<String> = []) -> ChatOutline.Entry {
        ChatOutline.Entry(id: id, messageID: id, kind: kind, weight: weight, pieceIDs: pieces)
    }

    private var entries: [ChatOutline.Entry] {
        [
            entry("a", .prompt("Ask"), weight: 40, pieces: ["a1"]),
            entry("b", .response, weight: 25, pieces: ["b1", "b2"]),
            entry("c", .prompt("Again"), weight: 10, pieces: ["c1"]),
            entry("d", .response, weight: 1, pieces: ["d1"])
        ]
    }

    @Test func barsStackWithTheSpacing() {
        let layout = ChatMinimap.railLayout(for: entries, spacing: 2, railWidth: 8)
        let rows = layout.bars.map(\.row)

        // A prompt row is its 4 pt bar plus 2 pt above and below, whatever
        // its weight.
        #expect(rows[0] == CGRect(x: 0, y: 0, width: 8, height: 8))
        #expect(rows[1] == CGRect(x: 0, y: 10, width: 8, height: 25))
        #expect(rows[2] == CGRect(x: 0, y: 37, width: 8, height: 8))
        #expect(layout.bars[0].bar == CGRect(x: 0, y: 2, width: 8, height: 4))
        #expect(layout.bars[1].bar == CGRect(x: 4, y: 10, width: 4, height: 25))
    }

    @Test func aShortResponseTakesTheMinimumHeight() {
        let layout = ChatMinimap.railLayout(for: entries, spacing: 2, railWidth: 8)

        #expect(layout.bars[3].row.height == ChatMinimap.minimumEntryHeight)
    }

    @Test func theHeightEndsAtTheLastBar() {
        let layout = ChatMinimap.railLayout(for: entries, spacing: 2, railWidth: 8)

        #expect(layout.height == layout.bars.last?.row.maxY)
        let rowsAndGaps: [CGFloat] = [8, 2, 25, 2, 8, 2, 3]
        #expect(layout.height == rowsAndGaps.reduce(0, +))
        #expect(ChatMinimap.railLayout(for: [], railWidth: 8).height == 0)
    }

    @Test func theVisibleEntriesAreTheOnesWithAPieceOnScreen() {
        let emphasis = ChatMinimap.emphasis(of: entries, visiblePieceIDs: ["b2", "c1", "elsewhere"])

        #expect(emphasis == [0, 1, 1, 0])
    }

    @Test func aClickLandsOnTheRowUnderIt() {
        let bars = ChatMinimap.railLayout(for: entries, spacing: 2, railWidth: 8).bars

        #expect(ChatMinimap.entryIndex(at: CGPoint(x: 1, y: 1), in: bars) == 0)
        // Left of a response's bar is still its row, as the mounted button's
        // content shape is.
        #expect(ChatMinimap.entryIndex(at: CGPoint(x: 1, y: 20), in: bars) == 1)
        #expect(ChatMinimap.entryIndex(at: CGPoint(x: 1, y: 9), in: bars) == nil)
        #expect(ChatMinimap.entryIndex(at: CGPoint(x: 1, y: 500), in: bars) == nil)
    }
}

/// The emphasis vector interpolates per entry, reading a missing entry as at
/// rest, so a rail that gains entries mid-animation still eases.
struct EmphasisVectorTests {
    @Test func unequalLengthsPadWithZero() {
        let sum = EmphasisVector([1, 0.5]) + EmphasisVector([0, 0.5, 1])

        #expect(sum.values == [1, 1, 1])
        #expect(EmphasisVector([1, 0]) == EmphasisVector([1]))
    }

    @Test func scalingHalvesEachComponent() {
        var vector = EmphasisVector([1, 0.5])
        vector.scale(by: 0.5)

        #expect(vector.values == [0.5, 0.25])
    }
}
