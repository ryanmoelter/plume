import SwiftUI

private struct ChatHugsContentKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Set on the user's bubble, where the container sizes to its text rather
    /// than the text filling a column. `ListItemPadding` reads it so a short
    /// message stays short instead of stretching to reading measure.
    var chatHugsContent: Bool {
        get { self[ChatHugsContentKey.self] }
        set { self[ChatHugsContentKey.self] = newValue }
    }
}

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
    @Environment(\.chatHugsContent) private var hugsContent

    let bleed: Bool
    let column: ChatColumn
    let vertical: Bool

    func body(content: Content) -> some View {
        content
            // Fill the column and left-align inside it, so a one-line
            // paragraph starts at the same left edge as a wrapped one rather
            // than centering itself in a frame its own width. A hugging
            // container sizes to its text instead, so a short message does
            // not stretch to reading measure.
            .frame(maxWidth: hugsContent ? nil : .infinity, alignment: .leading)
            // Padding goes inside the clamp: the column measures the content
            // itself, so a padded item occupies `maxWidth + gutter * 2` and
            // the text inside it still measures a full `maxWidth`.
            .padding(.horizontal, gutter)
            .padding(.vertical, vertical ? ChatMetrics.verticalPadding : 0)
            .frame(maxWidth: clampedWidth)
            // The column itself centers in whatever contains it.
            .frame(maxWidth: fillsContainer ? .infinity : nil, alignment: .center)
    }

    /// A hugging item takes no column — its container is already sized to it,
    /// so clamping here would only center the text in a box it doesn't fill.
    private var clampedWidth: CGFloat? {
        guard !hugsContent else { return nil }
        switch column {
        case .padded: return maxWidth + gutter * 2
        case .unpadded: return maxWidth
        case .none: return nil
        }
    }

    /// A hugging item has no column to center in — it is as wide as it is.
    private var fillsContainer: Bool {
        !hugsContent && column != .none
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

    /// Clamps text to reading measure inside a container that is itself
    /// wider. A card may take the bleed column, but the prose in it still
    /// wraps at the same measure as prose anywhere else.
    func chatTextColumn() -> some View {
        modifier(ChatTextColumn())
    }
}

private struct ChatTextColumn: ViewModifier {
    @Environment(\.chatFontSize) private var fontSize

    func body(content: Content) -> some View {
        content
            .frame(
                maxWidth: ChatMetrics.maxContentWidth(forFontSize: fontSize),
                alignment: .leading
            )
            // The clamped column then centers in the wider one holding it, so
            // a card's prose sits under the same axis as prose outside it.
            .frame(maxWidth: .infinity, alignment: .center)
    }
}
