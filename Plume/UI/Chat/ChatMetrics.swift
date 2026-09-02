import Foundation

/// Pure layout math for the chat message list.
enum ChatMetrics {
    /// A readable column width of roughly 80 characters, derived from the
    /// current chat body font size at ~0.5em average glyph advance for a
    /// proportional font.
    static func maxContentWidth(forFontSize fontSize: CGFloat) -> CGFloat {
        fontSize * 40
    }

    /// Room for what doesn't fit prose measure — code blocks, tables, the
    /// plan panel. Scales with the font like the content column, so the two
    /// keep their proportion as the text grows.
    static func maxBleedWidth(forFontSize fontSize: CGFloat) -> CGFloat {
        fontSize * 50
    }

    /// Empty space below the last message, roughly 4-5 lines tall, so the
    /// true bottom of the conversation is visually obvious rather than
    /// butting straight up against the composer.
    static func bottomPadding(forFontSize fontSize: CGFloat) -> CGFloat {
        fontSize * 4.5
    }

    /// The gutter between a bleed item's column and the window edge.
    static let horizontalPadding: CGFloat = 16

    /// How far content steps in from the bleed column around it. Keeps the
    /// two distinguishable when the window is too narrow for either to reach
    /// its maximum width.
    static let contentInset: CGFloat = 12

    /// Vertical breathing room around a list item.
    static let verticalPadding: CGFloat = 16
}
