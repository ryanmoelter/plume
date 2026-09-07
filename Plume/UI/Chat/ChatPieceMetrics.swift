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

    private static let proseLineHeight: CGFloat = 20
    private static let prosePadding: CGFloat = 8
    private static let charactersPerLine = 90
    private static let codeLineHeight: CGFloat = 17
    private static let codePadding: CGFloat = 28
    private static let listItemHeight: CGFloat = 22

    /// A rough height for the block, or nil for the kinds that are never
    /// split and so never need one.
    static func estimatedHeight(of block: MarkdownBlock) -> CGFloat? {
        switch block {
        case .paragraph(let text), .quote(let text):
            return CGFloat(wrappedLines(of: text)) * proseLineHeight + prosePadding
        case .codeBlock(_, let code):
            return CGFloat(lines(of: code).count) * codeLineHeight + codePadding
        case .bulletList(let items), .numberedList(let items):
            return CGFloat(items.count) * listItemHeight
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

    static func splitsList(_ items: [String]) -> Bool {
        guard items.count > 2 * listSegmentItems else { return false }
        return CGFloat(items.count) * listItemHeight > maxPieceHeight
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
