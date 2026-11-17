import Foundation

/// Which edge of the chat the minimap runs down.
enum MinimapSide: String, CaseIterable {
    case leading
    case trailing
}

/// How the minimap spaces its rows.
enum MinimapSpacing: String, CaseIterable {
    /// Every row the same distance apart, with a faint tick in each gap
    /// showing how much the agent wrote there.
    case even
    /// The gap after a row grows with how much the agent wrote there.
    case proportional
}

/// One row of the minimap: something the user said or was asked, or the end
/// of the conversation.
struct MinimapRow: Equatable {
    enum Kind: Equatable {
        case anchor(ChatOutline.Kind)
        /// The bottom of the conversation, where the list follows new
        /// content.
        case end
    }

    /// The piece a click scrolls to. Empty for the end row.
    var id: String
    var kind: Kind
    /// The compressed weight of the agent output after this row, zero when
    /// the next row follows directly.
    var trailingWeight: CGFloat
    /// The anchor's pieces and the agent output after it, so the row reads
    /// as on screen while any of its turn is.
    var pieceIDs: Set<String>

    var label: String {
        switch kind {
        case .anchor(let kind): kind.text
        case .end: "End of conversation"
        }
    }

    var isEnd: Bool { kind == .end }
}

/// Where each minimap row sits, in the map's own content space: 0 at the top
/// of the first row, growing down.
struct MinimapLayout: Equatable {
    var rows: [MinimapRow] = []
    var spacing: MinimapSpacing = .even
    /// Each row's vertical center.
    var positions: [CGFloat] = []
    /// For each row, how strongly the gap after it is marked, 0...1. Only
    /// even spacing draws them; proportional spacing shows the same thing as
    /// distance.
    var tickStrengths: [CGFloat] = []
    var contentHeight: CGFloat = 0
    private var rowByPiece: [String: Int] = [:]
    private var rowByID: [String: Int] = [:]

    /// What every row draws at, whatever its weight, so a bar's thickness
    /// never says anything about its turn.
    static let rowHeight: CGFloat = 2
    static let evenPitch: CGFloat = 7
    /// The closest two rows sit with nothing between them, in proportional
    /// spacing.
    static let proportionalMinimumPitch: CGFloat = 5
    /// Points of gap per unit of `ChatOutlineBuilder` response weight.
    static let proportionalPointsPerWeight: CGFloat = 0.3

    init() {}

    init(outline: ChatOutline, spacing: MinimapSpacing) {
        self.init(rows: Self.rows(from: outline), spacing: spacing)
    }

    init(rows: [MinimapRow], spacing: MinimapSpacing) {
        self.rows = rows
        self.spacing = spacing
        var y = Self.rowHeight / 2
        positions.reserveCapacity(rows.count)
        tickStrengths.reserveCapacity(rows.count)
        for (index, row) in rows.enumerated() {
            positions.append(y)
            tickStrengths.append(Self.tickStrength(forWeight: row.trailingWeight))
            y += Self.pitch(afterWeight: row.trailingWeight, spacing: spacing)
            for piece in row.pieceIDs { rowByPiece[piece] = index }
            rowByID[row.id] = index
        }
        contentHeight = (positions.last ?? 0) + Self.rowHeight / 2
    }

    var isEmpty: Bool { rows.isEmpty }

    static func pitch(afterWeight weight: CGFloat, spacing: MinimapSpacing) -> CGFloat {
        switch spacing {
        case .even: evenPitch
        case .proportional: proportionalMinimumPitch + weight * proportionalPointsPerWeight
        }
    }

    static func tickStrength(forWeight weight: CGFloat) -> CGFloat {
        guard weight > 0 else { return 0 }
        return min(max(weight / ChatOutlineBuilder.maximumResponseWeight, 0), 1)
    }

    /// Anchors become the rows, each response folds into the row before it,
    /// and an end row closes the list. A response before any anchor belongs
    /// to the first row, so it still reads as on screen.
    static func rows(from outline: ChatOutline) -> [MinimapRow] {
        var rows: [MinimapRow] = []
        var leadingPieces: Set<String> = []
        for entry in outline.entries {
            if entry.kind.isUserInput {
                rows.append(MinimapRow(id: entry.id, kind: .anchor(entry.kind), trailingWeight: 0, pieceIDs: entry.pieceIDs))
            } else if rows.isEmpty {
                leadingPieces.formUnion(entry.pieceIDs)
            } else {
                rows[rows.count - 1].trailingWeight += entry.weight
                rows[rows.count - 1].pieceIDs.formUnion(entry.pieceIDs)
            }
        }
        if !leadingPieces.isEmpty, !rows.isEmpty {
            rows[0].pieceIDs.formUnion(leadingPieces)
        }
        rows.append(MinimapRow(id: "", kind: .end, trailingWeight: 0, pieceIDs: rows.isEmpty ? leadingPieces : []))
        return rows
    }

    /// A row's index by its id, which outlives the index as rows are added.
    /// The end row's id is empty.
    func index(ofRowID id: String) -> Int? {
        rowByID[id]
    }

    func visibleRows(for pieceIDs: Set<String>) -> Set<Int> {
        Set(pieceIDs.compactMap { rowByPiece[$0] })
    }

    /// The middle of what is on screen, in content space: each visible row
    /// counts as its row plus the gap after it, averaged so the map tracks
    /// the middle of the viewport rather than snapping between its edges.
    func focusY(visibleRows: Set<Int>) -> CGFloat? {
        guard !visibleRows.isEmpty else { return nil }
        let centers = visibleRows.map { index in
            let next = index + 1 < positions.count ? positions[index + 1] : positions[index]
            return (positions[index] + next) / 2
        }
        return centers.reduce(0, +) / CGFloat(centers.count)
    }

    /// The row whose bar is nearest `y`, which is how hovering and clicking
    /// snap to rows.
    func nearestRow(toY y: CGFloat) -> Int? {
        guard !positions.isEmpty else { return nil }
        var low = 0
        var high = positions.count - 1
        while low < high {
            let mid = (low + high) / 2
            if positions[mid] < y { low = mid + 1 } else { high = mid }
        }
        if low > 0, abs(positions[low - 1] - y) <= abs(positions[low] - y) { return low - 1 }
        return low
    }

    static func == (lhs: MinimapLayout, rhs: MinimapLayout) -> Bool {
        lhs.rows == rhs.rows && lhs.spacing == rhs.spacing
    }
}
