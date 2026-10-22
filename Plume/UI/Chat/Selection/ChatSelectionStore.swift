import AppKit
import Observation
import SwiftUI

/// One piece's share of the selection, observed by that piece's `Text`s only,
/// so a drag re-renders the pieces it crosses and nothing else.
@Observable
final class PieceSelection {
    /// Piece-local, in `ChatSelectableText` offsets.
    var range: Range<Int>?
    /// False while the transcript is not the key window's first responder,
    /// which draws the selection in the inactive color.
    var isActive = true
}

/// Owns the transcript's selection, which lives in the model rather than in
/// any view so it survives its rows being freed.
///
/// Not observable itself: views observe their own piece's `PieceSelection`,
/// which the store creates from AppKit (`box(for:)` in `makeRoot`), never from
/// a `body`.
@MainActor
final class ChatSelectionStore {
    private(set) var selection: ChatSelection?
    private(set) var isActive = false
    private(set) var order = ChatPieceOrder([])
    private var lengths: [String: Int] = [:]
    private var boxes: [String: PieceSelection] = [:]
    let layouts = ChatTextLayoutRegistry()

    var hasSelection: Bool { selection.map { !$0.isCollapsed } ?? false }

    func box(for pieceID: String) -> PieceSelection {
        if let box = boxes[pieceID] { return box }
        let box = PieceSelection()
        box.range = range(in: pieceID)
        box.isActive = isActive
        boxes[pieceID] = box
        return box
    }

    func release(_ pieceID: String) {
        boxes[pieceID] = nil
        layouts.remove(pieceID)
    }

    /// Takes the list's new pieces, clamping the selection onto what is left.
    func update(pieces: [ChatPiece], previousIDs: [String]) {
        let ids = pieces.map(\.id)
        order = ChatPieceOrder(ids)
        lengths = Dictionary(pieces.map { ($0.id, $0.selectableLength) }, uniquingKeysWith: { first, _ in first })
        guard let selection else { return }
        set(selection.clamped(from: previousIDs, toIDs: ids) { self.lengths[$0] ?? 0 })
    }

    func set(_ selection: ChatSelection?) {
        self.selection = selection
        for (id, box) in boxes {
            let range = range(in: id)
            if box.range != range { box.range = range }
        }
    }

    func setActive(_ isActive: Bool) {
        guard isActive != self.isActive else { return }
        self.isActive = isActive
        for box in boxes.values where box.isActive != isActive { box.isActive = isActive }
    }

    func length(of pieceID: String) -> Int { lengths[pieceID] ?? 0 }

    func isSelectable(_ pieceID: String) -> Bool { length(of: pieceID) > 0 }

    func index(of pieceID: String) -> Int? { order.index(of: pieceID) }

    /// Nil when the selection misses the piece or covers none of it.
    private func range(in pieceID: String) -> Range<Int>? {
        guard let bounds = selection?.bounds(in: order), let index = order.index(of: pieceID),
              let startIndex = order.index(of: bounds.start.pieceID),
              let endIndex = order.index(of: bounds.end.pieceID),
              startIndex <= index, index <= endIndex else { return nil }
        let lower = index == startIndex ? bounds.start.offset : 0
        let upper = index == endIndex ? bounds.end.offset : length(of: pieceID)
        return lower < upper ? lower..<upper : nil
    }
}

/// Where each selectable `Text` of the realized rows sits and how it laid
/// out, recorded from preference and geometry callbacks rather than from a
/// renderer's draw.
@MainActor
final class ChatTextLayoutRegistry {
    struct Entry {
        /// Where the `Text` starts in its piece's selectable text.
        var offset: Int
        var text: String
        /// The recorder that wrote it. A pooled row's old root can report
        /// disappearing after the same text has registered again elsewhere.
        var owner: UUID
        var layout: Text.Layout?
        /// In the row's coordinate space, `ChatSelectionGeometry.rowSpace`.
        var frame: CGRect = .zero
    }

    private(set) var entries: [String: [Int: Entry]] = [:]

    func setLayout(_ layout: Text.Layout?, text: String, pieceID: String, offset: Int, owner: UUID) {
        update(pieceID: pieceID, offset: offset, text: text, owner: owner) { $0.layout = layout }
    }

    func setFrame(_ frame: CGRect, text: String, pieceID: String, offset: Int, owner: UUID) {
        update(pieceID: pieceID, offset: offset, text: text, owner: owner) { $0.frame = frame }
    }

    func remove(_ pieceID: String, offset: Int, owner: UUID) {
        guard entries[pieceID]?[offset]?.owner == owner else { return }
        entries[pieceID]?[offset] = nil
    }

    /// A recorder whose `Text` moved to a new offset, as an item does when an
    /// earlier item's text changes length, leaves no entry at the old one.
    private func update(pieceID: String, offset: Int, text: String, owner: UUID, _ change: (inout Entry) -> Void) {
        var piece = entries[pieceID] ?? [:]
        for (other, entry) in piece where entry.owner == owner && other != offset { piece[other] = nil }
        var entry = piece[offset] ?? Entry(offset: offset, text: text, owner: owner)
        entry.text = text
        entry.owner = owner
        change(&entry)
        piece[offset] = entry
        entries[pieceID] = piece
    }

    func remove(_ pieceID: String) {
        entries[pieceID] = nil
    }

    /// The piece's `Text`s in reading order.
    func sortedEntries(of pieceID: String) -> [Entry] {
        (entries[pieceID]?.values).map { $0.sorted { $0.offset < $1.offset } } ?? []
    }

    /// Whether `point`, in the row's coordinates, lands on one of the
    /// piece's `Text`s.
    func isOnText(_ point: CGPoint, pieceID: String) -> Bool {
        entries[pieceID]?.values.contains { $0.frame.contains(point) } ?? false
    }

    /// The offset nearest `point`, in the row's coordinates. A point beside
    /// every `Text` takes the nearest one's nearest line; above or below them
    /// all, the start or end of the piece.
    ///
    /// `character` asks for the start of the glyph under the point rather
    /// than the nearest boundary, which is what a word lookup needs: the
    /// boundary after a word's last letter is already outside the word.
    func offset(at point: CGPoint, pieceID: String, length: Int, character: Bool = false) -> Int {
        let sorted = sortedEntries(of: pieceID).filter { $0.layout != nil }
        guard let first = sorted.first else { return 0 }
        if point.y < first.frame.minY { return 0 }
        if let last = sorted.last, point.y >= sorted.map(\.frame.maxY).max() ?? last.frame.maxY { return length }
        let band = sorted.filter { $0.frame.minY <= point.y && point.y < $0.frame.maxY }
        if let entry = band.min(by: { horizontalDistance(point.x, $0.frame) < horizontalDistance(point.x, $1.frame) }) {
            let local = CGPoint(x: point.x - entry.frame.minX, y: point.y - entry.frame.minY)
            return entry.offset + Self.offset(at: local, in: entry, character: character)
        }
        // In the gap between two `Text`s, such as the space between list items.
        let below = sorted.first { $0.frame.minY > point.y }
        return below?.offset ?? length
    }

    private func horizontalDistance(_ x: CGFloat, _ frame: CGRect) -> CGFloat {
        x < frame.minX ? frame.minX - x : (x > frame.maxX ? x - frame.maxX : 0)
    }

    /// The offset within one `Text` nearest a point in its own coordinates:
    /// the nearest line, then the glyph boundary nearest the point along it.
    static func offset(at point: CGPoint, in entry: Entry, character: Bool = false) -> Int {
        guard let layout = entry.layout, let origin = ChatTextGeometry.origin(of: layout) else { return 0 }
        let length = entry.text.utf16.count
        let lineStarts = WordReveal.lineStarts(
            of: layout, from: origin, paragraphStarts: WordReveal.paragraphStarts(in: entry.text)
        )
        let lines = Array(zip(layout, lineStarts))
        guard !lines.isEmpty else { return 0 }
        let nearest = lines.min { lhs, rhs in
            verticalDistance(point.y, lhs.0.typographicBounds.rect) < verticalDistance(point.y, rhs.0.typographicBounds.rect)
        }!
        let starts = ChatTextGeometry.sliceStarts(of: layout, from: origin, lineStarts: lineStarts)
        let (line, lineStart) = nearest
        var best: (distance: CGFloat, offset: Int)?
        for run in line {
            for slice in run {
                guard let index = slice.characterIndices.first else { continue }
                let start = lineStart + origin.distance(to: index)
                let rect = slice.typographicBounds.rect
                if character {
                    let distance = point.x < rect.minX ? rect.minX - point.x : max(point.x - rect.maxX, 0)
                    if best == nil || distance < best!.distance { best = (distance, start) }
                    continue
                }
                let end = ChatTextGeometry.end(ofSliceAt: start, in: starts, length: length)
                for (x, offset) in [(rect.minX, start), (rect.maxX, end)] {
                    let distance = abs(point.x - x)
                    if best == nil || distance < best!.distance { best = (distance, offset) }
                }
            }
        }
        return min(max(best?.offset ?? lineStart, 0), length)
    }

    private static func verticalDistance(_ y: CGFloat, _ rect: CGRect) -> CGFloat {
        y < rect.minY ? rect.minY - y : (y > rect.maxY ? y - rect.maxY : 0)
    }
}

enum ChatTextGeometry {
    /// The index the layout's offsets count from. The smallest index rather
    /// than the first run's, because a right-to-left line lays its logically
    /// first run out last.
    static func origin(of layout: Text.Layout) -> Text.Layout.CharacterIndex? {
        layout.lazy.flatMap { line in line.lazy.compactMap { $0.characterIndices.first } }.min()
    }

    /// Every glyph's start offset, ascending. A glyph reports only its
    /// cluster's first index, so it runs to the next glyph's start.
    static func sliceStarts(of layout: Text.Layout, from origin: Text.Layout.CharacterIndex, lineStarts: [Int]) -> [Int] {
        var starts: [Int] = []
        for (line, lineStart) in zip(layout, lineStarts) {
            for run in line {
                for slice in run {
                    if let index = slice.characterIndices.first { starts.append(lineStart + origin.distance(to: index)) }
                }
            }
        }
        return Array(Set(starts)).sorted()
    }

    static func end(ofSliceAt start: Int, in starts: [Int], length: Int) -> Int {
        var low = 0, high = starts.count
        while low < high {
            let mid = (low + high) / 2
            if starts[mid] <= start { low = mid + 1 } else { high = mid }
        }
        return low < starts.count ? starts[low] : length
    }
}

enum ChatSelectionGeometry {
    /// The coordinate space every row's root names, which the registry's
    /// frames are measured in and which matches the hosting view's own.
    static let rowSpace = "plume.chat.row"
}

/// What a selectable `Text` needs to take part in the transcript's selection:
/// its piece's share, and where it starts in the piece.
struct ChatSelectionSpan: Equatable {
    let store: ChatSelectionStore
    let pieceID: String
    let piece: PieceSelection
    var offset: Int = 0

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.store === rhs.store && lhs.piece === rhs.piece && lhs.pieceID == rhs.pieceID && lhs.offset == rhs.offset
    }
}

extension EnvironmentValues {
    /// Nil everywhere but a markdown piece of the chat list. A `Text` without
    /// one keeps SwiftUI's own selection.
    @Entry var chatSelectionSpan: ChatSelectionSpan?
}
