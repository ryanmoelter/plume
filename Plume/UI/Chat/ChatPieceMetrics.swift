import Foundation

/// The ceiling on a lazy item's height, and the crude estimates used to
/// decide whether a block exceeds it.
///
/// The estimates only ever choose whether to split. Nothing measures text and
/// nothing feeds a measured height back in — a model that depends on layout
/// results is the feedback loop `docs/chat-list-hang.md` exists to remove.
enum ChatPieceMetrics {
    /// The tallest a piece should be. Trials in the hang diagnosis showed a
    /// 300 pt ceiling beside the list's 23 pt rows never reproducing.
    static let maxPieceHeight: CGFloat = 300

    /// The most lines a code segment carries.
    static let codeSegmentLines = 16

    /// The most items a list segment carries.
    static let listSegmentItems = 12

    private static let proseLineHeight: CGFloat = 24
    private static let prosePadding: CGFloat = 8
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

    /// A rough height for the block, or nil for the kinds that are never
    /// split and so never need one.
    static func estimatedHeight(of block: MarkdownBlock) -> CGFloat? {
        switch block {
        case .paragraph(let text), .quote(let text):
            return CGFloat(wrappedLines(of: text)) * proseLineHeight + prosePadding
        case .codeBlock(_, let code):
            return CGFloat(lines(of: code).count) * codeLineHeight + codePadding
        case .bulletList(let items), .numberedList(let items):
            return items.reduce(0) { $0 + height(ofItem: $1) }
        case .heading, .table, .rule:
            return nil
        }
    }

    static func lines(of code: String) -> [String] {
        code.components(separatedBy: "\n")
    }

    /// Whether a code block is long enough to be worth splitting. Ordinary
    /// blocks stay whole: a segment of its own costs a horizontal scroll view
    /// that no longer scrolls with the rest of the block.
    static func splitsCode(_ code: String) -> Bool {
        let count = lines(of: code).count
        guard count > 2 * codeSegmentLines else { return false }
        return CGFloat(count) * codeLineHeight + codePadding > maxPieceHeight
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
