import SwiftUI

/// Crude estimates used to decide how a chat piece splits, plus fixed sizes
/// its rows draw at.
enum ChatPieceMetrics {
    /// The tallest the disclosed body of a row draws — a tool call's input
    /// and result, a thinking block, an injected line. Past it the body
    /// scrolls inside itself rather than growing without limit: an injected
    /// line can carry a whole approved plan, and a tool result can run to
    /// tens of thousands of characters.
    static let maxDisclosedHeight: CGFloat = 240

    /// The header naming a code block's language and carrying its copy
    /// button. Fixed rather than measured, and drawn on every block.
    static let codeHeaderHeight: CGFloat = 28

    /// A run of prose broken into one piece per paragraph.
    ///
    /// A paragraph break is a gap the source already has, so the seam costs
    /// the reader nothing. A single paragraph has no seam to use and stays
    /// whole, however tall.
    static func proseParagraphs(_ text: String) -> [String] {
        let paragraphs = text
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return paragraphs.isEmpty ? [text] : paragraphs
    }
}
