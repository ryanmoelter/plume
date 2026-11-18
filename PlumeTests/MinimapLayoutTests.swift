import Foundation
import Testing
@testable import Plume

/// The minimap's rows: one per prompt or question, each carrying the agent
/// output after it as weight, closed by an end row, and placed evenly or in
/// proportion to that weight.
@MainActor
struct MinimapLayoutTests {
    private func entry(_ id: String, _ kind: ChatOutline.Kind, weight: CGFloat = 0) -> ChatOutline.Entry {
        ChatOutline.Entry(id: id, messageID: id, kind: kind, weight: weight, pieceIDs: [id])
    }

    private let outline = ChatOutline(entries: [
        ChatOutline.Entry(id: "p1", messageID: "p1", kind: .prompt("First"), weight: 22, pieceIDs: ["p1"]),
        ChatOutline.Entry(id: "r1", messageID: "r1", kind: .response, weight: 40, pieceIDs: ["r1", "r1b"]),
        ChatOutline.Entry(id: "p2", messageID: "p2", kind: .prompt("Second"), weight: 22, pieceIDs: ["p2"]),
        ChatOutline.Entry(id: "p3", messageID: "p3", kind: .question("Which?"), weight: 22, pieceIDs: ["p3"]),
        ChatOutline.Entry(id: "r3", messageID: "r3", kind: .response, weight: 8, pieceIDs: ["r3"])
    ])

    @Test func anchorsAreTheRowsAndResponsesFoldIntoTheRowBefore() {
        let rows = MinimapLayout.rows(from: outline)

        #expect(rows.map(\.id) == ["p1", "p2", "p3", ""])
        #expect(rows.map(\.trailingWeight) == [40, 0, 8, 0])
        #expect(rows[0].pieceIDs == ["p1", "r1", "r1b"])
    }

    @Test func theEndRowIsLast() {
        let rows = MinimapLayout.rows(from: outline)
        #expect(rows.last?.isEnd == true)
        #expect(rows.dropLast().allSatisfy { !$0.isEnd })
        #expect(MinimapLayout.rows(from: ChatOutline()).map(\.isEnd) == [true])
    }

    @Test func aResponseBeforeAnyAnchorBelongsToTheFirstRow() {
        let rows = MinimapLayout.rows(from: ChatOutline(entries: [
            entry("r0", .response, weight: 10),
            entry("p1", .prompt("First"))
        ]))
        #expect(rows.first?.pieceIDs == ["r0", "p1"])
        #expect(rows.first?.trailingWeight == 0)
    }

    @Test func evenSpacingPlacesRowsAtOnePitch() {
        let layout = MinimapLayout(outline: outline, spacing: .even)
        let gaps = zip(layout.positions.dropFirst(), layout.positions).map { $0 - $1 }
        #expect(gaps.allSatisfy { $0 == MinimapLayout.evenPitch })
    }

    @Test func proportionalSpacingWidensTheGapAfterMoreText() {
        let layout = MinimapLayout(outline: outline, spacing: .proportional)
        let gaps = zip(layout.positions.dropFirst(), layout.positions).map { $0 - $1 }
        // After 40, after nothing, after 8.
        #expect(gaps[0] > gaps[2])
        #expect(gaps[2] > gaps[1])
        #expect(gaps[1] == MinimapLayout.proportionalMinimumPitch)
    }

    @Test func positionsRunTopToBottomInBothModes() {
        for spacing in MinimapSpacing.allCases {
            let layout = MinimapLayout(outline: outline, spacing: spacing)
            #expect(layout.positions == layout.positions.sorted())
            #expect(layout.contentHeight >= (layout.positions.last ?? 0))
        }
    }

    @Test func everyRowHasTheSameHeight() {
        // Row height is a constant rather than per row: a row's size never
        // varies with its turn, in either spacing mode.
        let even = MinimapLayout(outline: outline, spacing: .even)
        let proportional = MinimapLayout(outline: outline, spacing: .proportional)
        #expect(even.contentHeight == (even.positions.last ?? 0) + MinimapLayout.rowHeight / 2)
        #expect(proportional.contentHeight == (proportional.positions.last ?? 0) + MinimapLayout.rowHeight / 2)
    }

    @Test func visibleRowsComeFromAnyPieceOfTheirTurn() {
        let layout = MinimapLayout(outline: outline, spacing: .even)
        #expect(layout.visibleRows(for: ["r1b"]) == [0])
        #expect(layout.visibleRows(for: ["p2", "r3"]) == [1, 2])
        #expect(layout.visibleRows(for: ["unknown"]).isEmpty)
    }

    @Test func focusSitsBetweenTheVisibleRows() throws {
        let layout = MinimapLayout(outline: outline, spacing: .even)
        let top = try #require(layout.focusY(visibleRows: [0]))
        let bottom = try #require(layout.focusY(visibleRows: [2]))
        let both = try #require(layout.focusY(visibleRows: [0, 2]))
        #expect(top < both)
        #expect(both < bottom)
        #expect(layout.focusY(visibleRows: []) == nil)
    }

    @Test func nearestRowSnaps() {
        let layout = MinimapLayout(outline: outline, spacing: .even)
        #expect(layout.nearestRow(toY: -50) == 0)
        #expect(layout.nearestRow(toY: layout.positions[1] + 1) == 1)
        #expect(layout.nearestRow(toY: layout.positions[2] - 1) == 2)
        #expect(layout.nearestRow(toY: 10_000) == layout.rows.count - 1)
        #expect(MinimapLayout().nearestRow(toY: 0) == nil)
    }

    @Test func aRowKeepsItsIdentityWhenAnAnchorIsAppended() {
        let before = MinimapLayout(outline: outline, spacing: .even)
        let longer = ChatOutline(entries: outline.entries + [entry("p4", .prompt("Fourth"))])
        let after = MinimapLayout(outline: longer, spacing: .even)

        #expect(before.index(ofRowID: "") == 3)
        #expect(after.index(ofRowID: "") == 4)
        #expect(after.index(ofRowID: "p2") == 1)
        #expect(after.index(ofRowID: "gone") == nil)
    }
}
