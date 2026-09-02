import SwiftUI

/// Sizes a chat item's own column.
///
/// Items own their width rather than inheriting one from the list, so a code
/// block can take the wider bleed column while the prose around it steps back
/// in to reading measure.
///
/// The nesting runs outside-in: a message row takes `.bleed`, and the prose
/// inside it steps in to `.content`. A code block adds nothing and simply
/// fills the bleed row it already sits in.
///
/// Horizontal padding and the column are one decision, because the gutter only
/// means anything against a clamped, centered column. Turning it off gives the
/// item its container's full width — the rare case.
private struct ListItemPadding: ViewModifier {
    @Environment(\.chatFontSize) private var fontSize

    let bleed: Bool
    let horizontal: Bool
    let vertical: Bool

    func body(content: Content) -> some View {
        content
            // Padding goes inside the clamp: the column measures the content
            // itself, so the item occupies `maxWidth + gutter * 2` and the
            // text inside it still measures a full `maxWidth`.
            .padding(.horizontal, horizontal ? gutter : 0)
            .padding(.vertical, vertical ? ChatMetrics.verticalPadding : 0)
            .frame(maxWidth: horizontal ? maxWidth + gutter * 2 : nil)
            .frame(maxWidth: .infinity, alignment: horizontal ? .center : .leading)
    }

    private var maxWidth: CGFloat {
        bleed
            ? ChatMetrics.maxBleedWidth(forFontSize: fontSize)
            : ChatMetrics.maxContentWidth(forFontSize: fontSize)
    }

    /// Content nests inside bleed, which has already paid the outer gutter.
    /// Content keeps a gutter of its own so that in a window too narrow for
    /// either column to reach its maximum, content still reads narrower than
    /// the bleed around it rather than collapsing flush against it.
    private var gutter: CGFloat {
        bleed ? ChatMetrics.horizontalPadding : ChatMetrics.contentInset
    }
}

extension View {
    /// Gives this item its own column in a chat list. See `ListItemPadding`.
    func listItemPadding(
        bleed: Bool = false,
        horizontal: Bool = true,
        vertical: Bool = true
    ) -> some View {
        modifier(ListItemPadding(bleed: bleed, horizontal: horizontal, vertical: vertical))
    }
}
