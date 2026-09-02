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

    /// Gap between blocks within one message — paragraph to paragraph, prose
    /// to code. Scales with the font so the rhythm holds at any size.
    static func blockSpacing(forFontSize fontSize: CGFloat) -> CGFloat {
        fontSize * 1.15
    }

    /// Extra space above a heading, on top of the usual block gap. A heading
    /// belongs to the text below it, so the space goes above only, and it
    /// tapers with the level: an H1 opens a section, an H5 barely interrupts.
    static func headingTopSpacing(level: Int, forFontSize fontSize: CGFloat) -> CGFloat {
        let multiplier: CGFloat = switch level {
        case 1: 1.4
        case 2: 1.0
        case 3: 0.65
        case 4: 0.35
        default: 0
        }
        return fontSize * multiplier
    }

    /// Extra leading between wrapped lines, on top of the font's own. Long
    /// prose at reading measure needs a little more air than the default.
    static func lineSpacing(forFontSize fontSize: CGFloat) -> CGFloat {
        fontSize * 0.22
    }
}
