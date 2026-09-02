import SwiftUI

/// How an item takes its column.
enum ChatColumn {
    /// A visible container: clamps to the column and paints a gutter around
    /// it. What prose and anything with a background wants.
    case padded

    /// An invisible container: clamps to the column but paints no gutter, so
    /// the visible items nested inside it pay for their own. A message row is
    /// this — it establishes the width its children measure against without
    /// adding an inset of its own.
    case unpadded

    /// No column at all; the item fills its container.
    case none
}

/// Sizes a chat item's own column.
///
/// Items own their width rather than inheriting one from the list, so a code
/// block can take the wider bleed column while the prose around it steps back
/// in to reading measure.
///
/// The nesting runs outside-in: a message row establishes `.bleed` as an
/// invisible container, and the prose inside it steps in to `.content` as a
/// visible one. A code block adds nothing and simply fills the bleed row it
/// already sits in. Only the innermost visible item pays a gutter, so nested
/// items never stack one inset on another.
private struct ListItemPadding: ViewModifier {
    @Environment(\.chatFontSize) private var fontSize

    let bleed: Bool
    let column: ChatColumn
    let vertical: Bool

    func body(content: Content) -> some View {
        content
            // Fill the column and left-align inside it, so a one-line
            // paragraph starts at the same left edge as a wrapped one rather
            // than centering itself in a frame its own width.
            .frame(maxWidth: .infinity, alignment: .leading)
            // Padding goes inside the clamp: the column measures the content
            // itself, so a padded item occupies `maxWidth + gutter * 2` and
            // the text inside it still measures a full `maxWidth`.
            .padding(.horizontal, gutter)
            .padding(.vertical, vertical ? ChatMetrics.verticalPadding : 0)
            .frame(maxWidth: clampedWidth)
            // The column itself centers in whatever contains it.
            .frame(maxWidth: .infinity, alignment: .center)
    }

    private var clampedWidth: CGFloat? {
        switch column {
        case .padded: maxWidth + gutter * 2
        case .unpadded: maxWidth
        case .none: nil
        }
    }

    private var maxWidth: CGFloat {
        bleed
            ? ChatMetrics.maxBleedWidth(forFontSize: fontSize)
            : ChatMetrics.maxContentWidth(forFontSize: fontSize)
    }

    /// Content steps in by less than bleed, so that in a window too narrow for
    /// either column to reach its maximum, content still reads narrower than
    /// the bleed around it rather than collapsing flush against it.
    private var gutter: CGFloat {
        guard column == .padded else { return 0 }
        return bleed ? ChatMetrics.horizontalPadding : ChatMetrics.contentInset
    }
}

extension View {
    /// Gives this item its own column in a chat list. See `ListItemPadding`.
    func listItemPadding(
        bleed: Bool = false,
        column: ChatColumn = .padded,
        vertical: Bool = true
    ) -> some View {
        modifier(ListItemPadding(bleed: bleed, column: column, vertical: vertical))
    }
}
