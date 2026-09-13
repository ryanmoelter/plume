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

    /// The header naming a code block's language and carrying its copy
    /// button. Fixed rather than measured, and drawn on every block, so the
    /// ceiling below can subtract it without consulting a layout result.
    static let codeHeaderHeight: CGFloat = 24

    private static let codeLineHeight: CGFloat = 17
    private static let codePadding: CGFloat = 28

    /// Whether a code block is taller than its ceiling, and so scrolls
    /// inside itself.
    ///
    /// The header sits above the scrolling region and is counted here, so a
    /// block that scrolls still draws within `maxCodeHeight` overall.
    static func scrollsCode(_ code: String) -> Bool {
        let count = code.components(separatedBy: "\n").count
        return CGFloat(count) * codeLineHeight + codePadding > scrollingCodeHeight
    }

    /// The height left for code once the header has taken its share.
    static var scrollingCodeHeight: CGFloat { maxCodeHeight - codeHeaderHeight }

    /// A run of prose broken into one piece per paragraph.
    ///
    /// Unconditional, unlike a list's ceiling check: a paragraph break is a
    /// gap the source already has, so the seam costs the reader nothing and
    /// there is no reason to wait for a height to justify it. Paragraphs are
    /// never merged, which keeps the heights the estimator sees even — its
    /// error comes from the spread within the realized set rather than from
    /// the number of items, and `docs/chat-list-hang.md`'s Trial E3 found a
    /// wall of small uniform rows harmless.
    ///
    /// A single paragraph has no seam to use and stays whole, however tall.
    static func proseParagraphs(_ text: String) -> [String] {
        let paragraphs = text
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return paragraphs.isEmpty ? [text] : paragraphs
    }

}
