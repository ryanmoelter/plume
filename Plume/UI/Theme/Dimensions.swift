import Foundation

/// Widths and spacing, resolved against the current font size.
///
/// The column widths scale with the type so the two keep their proportion as
/// the text grows: a reader who enlarges the font gets a wider column, not a
/// narrower one measured in the same points.
struct Dimensions {
    /// A readable column of roughly 80 characters, at ~0.5em average glyph
    /// advance for a proportional font.
    let contentWidth: CGFloat

    /// Room for what doesn't fit prose measure — code blocks, tables, the
    /// plan panel.
    let bleedWidth: CGFloat

    /// Empty space below the last message, roughly 4-5 lines tall, so the
    /// bottom of the conversation is visually obvious rather than butting
    /// against the composer.
    let listBottomPadding: CGFloat

    /// The gutter between a bleed item's column and the window edge.
    let horizontalGutter: CGFloat = 16

    /// How far content steps in from the bleed column around it. Keeps the
    /// two distinguishable when the window is too narrow for either to reach
    /// its maximum width.
    let contentInset: CGFloat = 12

    /// Vertical breathing room around a list item.
    let verticalPadding: CGFloat = 16

    init(bodySize: CGFloat) {
        contentWidth = bodySize * 40
        bleedWidth = bodySize * 50
        listBottomPadding = bodySize * 4.5
    }
}
