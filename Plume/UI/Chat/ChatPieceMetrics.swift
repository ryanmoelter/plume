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

    /// Whether a run of prose is over the ceiling and so splits by paragraph.
    ///
    /// A quote and a paragraph were left whole on the reading that prose is
    /// never long enough to be worth splitting. Real transcripts disagree: a
    /// planning thread's quotes run past 1,000 characters, which is several
    /// hundred points beside a 27 pt collapsed tool call.
    static func splitsProse(_ text: String) -> Bool {
        proseHeight(text) > maxPieceHeight
    }

    /// A run of prose broken at its blank lines. Paragraphs are never merged
    /// across a split, so the seam always falls where the source already had
    /// a gap and the reader sees nothing.
    ///
    /// Packed greedily against the ceiling rather than into equal shares:
    /// paragraphs vary enough in length that equal shares leave a piece over
    /// the ceiling, which is the one thing the split exists to prevent. A
    /// paragraph taller than the ceiling on its own still gets its own piece
    /// — there is no seam inside it to use.
    static func proseParagraphs(_ text: String) -> [String] {
        let paragraphs = text
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard paragraphs.count > 1 else { return paragraphs.isEmpty ? [text] : paragraphs }

        var result: [String] = []
        var current: [String] = []
        var height: CGFloat = 0
        for paragraph in paragraphs {
            let paragraphHeight = proseHeight(paragraph)
            if !current.isEmpty, height + paragraphHeight > maxPieceHeight {
                result.append(current.joined(separator: "\n\n"))
                current = []
                height = 0
            }
            current.append(paragraph)
            height += paragraphHeight
        }
        if !current.isEmpty { result.append(current.joined(separator: "\n\n")) }
        return result
    }

    private static func proseHeight(_ text: String) -> CGFloat {
        CGFloat(wrappedLines(of: text)) * proseLineHeight
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
