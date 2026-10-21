import Foundation

/// A point between two characters of one piece's selectable text.
struct ChatTextPosition: Hashable {
    var pieceID: String
    /// Piece-local, in the UTF-16 units `ChatSelectableText` counts.
    var offset: Int
}

/// The order pieces appear in the list, which positions in different pieces
/// are compared by.
struct ChatPieceOrder {
    private let indices: [String: Int]

    init(_ ids: [String]) {
        indices = Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func index(of id: String) -> Int? { indices[id] }
}

struct ChatSelection: Equatable {
    var anchor: ChatTextPosition
    var focus: ChatTextPosition

    struct Bounds: Equatable {
        var start: ChatTextPosition
        var end: ChatTextPosition
    }

    var isCollapsed: Bool { anchor == focus }

    /// The selection with its earlier end first, or nil when an end names a
    /// piece the order does not know.
    func bounds(in order: ChatPieceOrder) -> Bounds? {
        guard let anchorIndex = order.index(of: anchor.pieceID),
              let focusIndex = order.index(of: focus.pieceID) else { return nil }
        let anchorFirst = anchorIndex != focusIndex ? anchorIndex < focusIndex : anchor.offset <= focus.offset
        return anchorFirst ? Bounds(start: anchor, end: focus) : Bounds(start: focus, end: anchor)
    }

    /// Shift-click and shift-arrow: the anchor stays and the focus moves.
    func extended(to position: ChatTextPosition) -> ChatSelection {
        ChatSelection(anchor: anchor, focus: position)
    }

    static func expandToPiece(_ pieceID: String, length: Int) -> ChatSelection {
        ChatSelection(
            anchor: ChatTextPosition(pieceID: pieceID, offset: 0),
            focus: ChatTextPosition(pieceID: pieceID, offset: length)
        )
    }

    /// Nil where `position` has no word or gap to select.
    static func expandToWord(at position: ChatTextPosition, in text: ChatSelectableText) -> ChatSelection? {
        guard let range = text.wordRange(at: position.offset) else { return nil }
        return ChatSelection(
            anchor: ChatTextPosition(pieceID: position.pieceID, offset: range.lowerBound),
            focus: ChatTextPosition(pieceID: position.pieceID, offset: range.upperBound)
        )
    }

    /// A drag that began with a double-click: the word first clicked, `self`,
    /// grown by whole words to `word`.
    func extendedByWord(to word: ChatSelection, in order: ChatPieceOrder) -> ChatSelection? {
        guard let origin = bounds(in: order), let target = word.bounds(in: order) else { return nil }
        if Self.position(target.start, precedes: origin.start, in: order) {
            return ChatSelection(anchor: origin.end, focus: target.start)
        }
        let end = Self.position(origin.end, precedes: target.end, in: order) ? target.end : origin.end
        return ChatSelection(anchor: origin.start, focus: end)
    }

    private static func position(_ lhs: ChatTextPosition, precedes rhs: ChatTextPosition, in order: ChatPieceOrder) -> Bool {
        lhs != rhs && ChatSelection(anchor: lhs, focus: rhs).bounds(in: order)?.start == lhs
    }

    /// The selection after the list changed from `oldIDs` to `newIDs`.
    ///
    /// An end in a piece that shrank moves to its new end. An end in a piece
    /// that vanished, or has nothing selectable left, moves to the nearest
    /// surviving piece's boundary: the start of a later piece, or the end of an
    /// earlier one, the later winning a tie. Nil when no piece survives.
    func clamped(from oldIDs: [String], toIDs newIDs: [String], lengthOf length: (String) -> Int) -> ChatSelection? {
        let survivors = Set(newIDs.filter { length($0) > 0 })
        func clamp(_ position: ChatTextPosition) -> ChatTextPosition? {
            if survivors.contains(position.pieceID) {
                let offset = min(max(position.offset, 0), length(position.pieceID))
                return ChatTextPosition(pieceID: position.pieceID, offset: offset)
            }
            guard let index = oldIDs.firstIndex(of: position.pieceID) else { return nil }
            for distance in 1..<max(oldIDs.count, 2) {
                if oldIDs.indices.contains(index + distance), survivors.contains(oldIDs[index + distance]) {
                    return ChatTextPosition(pieceID: oldIDs[index + distance], offset: 0)
                }
                if oldIDs.indices.contains(index - distance), survivors.contains(oldIDs[index - distance]) {
                    let id = oldIDs[index - distance]
                    return ChatTextPosition(pieceID: id, offset: length(id))
                }
            }
            return nil
        }
        guard let anchor = clamp(anchor), let focus = clamp(focus) else { return nil }
        return ChatSelection(anchor: anchor, focus: focus)
    }

    func clamped(from oldIDs: [String], to pieces: [ChatPiece]) -> ChatSelection? {
        let lengths = Dictionary(pieces.map { ($0.id, ChatSelectableText.length(of: $0)) }, uniquingKeysWith: { first, _ in first })
        return clamped(from: oldIDs, toIDs: pieces.map(\.id)) { lengths[$0] ?? 0 }
    }
}
