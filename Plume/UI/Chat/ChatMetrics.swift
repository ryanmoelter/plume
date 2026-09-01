import Foundation

/// Pure layout math for the chat message list.
enum ChatMetrics {
    /// A readable column width of roughly 80 characters, derived from the
    /// current chat body font size at ~0.5em average glyph advance for a
    /// proportional font.
    static func maxContentWidth(forFontSize fontSize: CGFloat) -> CGFloat {
        fontSize * 40
    }

    /// Empty space below the last message, roughly 4-5 lines tall, so the
    /// true bottom of the conversation is visually obvious rather than
    /// butting straight up against the composer.
    static func bottomPadding(forFontSize fontSize: CGFloat) -> CGFloat {
        fontSize * 4.5
    }
}
