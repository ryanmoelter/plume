import Foundation

/// The ceiling on a lazy item's height, and the crude estimates used to
/// decide whether a block exceeds it.
///
/// The estimates only ever choose whether a block splits or scrolls inside
/// itself. Nothing measures text and nothing feeds a measured height back
/// in — a model that depends on layout results is the feedback loop
/// `docs/chat-list-hang.md` exists to remove.
enum ChatPieceMetrics {
    /// The tallest a piece should be. Trials in the hang diagnosis showed a
    /// 300 pt ceiling beside the list's 23 pt rows never reproducing.
    static let maxPieceHeight: CGFloat = 300

    /// The tallest a fenced code block draws. A longer one keeps its whole
    /// text and scrolls inside itself rather than splitting: a code block is
    /// one artifact, and slicing it costs the reader a continuous scroll.
    static let maxCodeHeight: CGFloat = maxPieceHeight

    /// The tallest the disclosed body of a row draws — a tool call's input
    /// and result, a thinking block, an injected line. Past it the body
    /// scrolls inside itself, so expanding one can never hand the lazy stack
    /// an item taller than the ceiling. Below `maxPieceHeight` because these
    /// bodies are asides: a 28,000 character tool result beside a 27 pt
    /// collapsed row is the height contrast the ceiling exists to prevent.
    static let maxDisclosedHeight: CGFloat = 240

    /// The most items a list segment carries.
    static let listSegmentItems = 12

    private static let proseLineHeight: CGFloat = 24
    /// Roughly what fits on a line of reading measure at the default body
    /// size. Deliberately low, as `proseLineHeight` is deliberately high:
    /// underestimating leaves a piece over the ceiling, which is the thing
    /// the ceiling exists to prevent, while overestimating only splits a
    /// list that would have fit — and a list's segments join at the gap its
    /// items already have between them.
    private static let charactersPerLine = 60
    private static let codeLineHeight: CGFloat = 17
    private static let codePadding: CGFloat = 28
    private static let listItemSpacing: CGFloat = 4

    /// Whether a code block is taller than its ceiling, and so scrolls
    /// inside itself.
    static func scrollsCode(_ code: String) -> Bool {
        let count = code.components(separatedBy: "\n").count
        return CGFloat(count) * codeLineHeight + codePadding > maxCodeHeight
    }

    /// Splitting a list costs only the gap its items already have between
    /// them, so unlike a code block it splits as soon as it is over the
    /// ceiling rather than waiting for a length that makes it worth it.
    static func splitsList(_ items: [String]) -> Bool {
        guard items.count > 1 else { return false }
        return items.reduce(0) { $0 + height(ofItem: $1) } > maxPieceHeight
    }

    /// Segments of equal length, as few as the ceiling allows, so a list
    /// just over it does not end on a segment of one item.
    static func listChunks(_ items: [String]) -> [[String]] {
        let total = items.reduce(0) { $0 + height(ofItem: $1) }
        let segments = max(1, Int((total / maxPieceHeight).rounded(.up)))
        let perSegment = max(1, (items.count + segments - 1) / segments)
        return chunks(items, limit: min(perSegment, listSegmentItems))
    }

    private static func height(ofItem item: String) -> CGFloat {
        CGFloat(wrappedLines(of: item)) * proseLineHeight + listItemSpacing
    }

    /// Splits into as few chunks as the limit allows, all of the same size, so
    /// a block just over the threshold does not end on a one-line segment.
    static func chunks<T>(_ items: [T], limit: Int) -> [[T]] {
        guard !items.isEmpty, limit > 0 else { return [items] }
        let count = (items.count + limit - 1) / limit
        let size = (items.count + count - 1) / count
        return stride(from: 0, to: items.count, by: size).map {
            Array(items[$0..<min($0 + size, items.count)])
        }
    }

    private static func wrappedLines(of text: String) -> Int {
        let explicit = text.components(separatedBy: "\n").count
        return explicit + text.count / charactersPerLine
    }
}
