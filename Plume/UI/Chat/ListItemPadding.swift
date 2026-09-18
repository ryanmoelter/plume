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

/// Sizes a chat item's own column.
///
/// Items own their width rather than inheriting one from the list, so a code
/// block can take the wider bleed column while the prose around it steps back
/// in to reading measure.
///
/// The nesting runs outside-in: a message row takes the bleed column, and the
/// prose inside it steps back in to content measure. A code block adds nothing
/// and simply fills the bleed row it already sits in.
///
/// The edge padding sits outside the clamp, so a column's width is the item's
/// real visual bound wherever the window can seat it. Every item keeps that
/// band, since it is what the collapsed minimap overlays — an item that
/// skipped it would draw under the rail.
private struct ListItemPadding: ViewModifier, ThemedView {
    @Environment(\.theme) var theme
    @Environment(\.chatHugsContent) private var hugsContent

    let bleed: Bool
    let vertical: Bool

    func body(content: Content) -> some View {
        content
            // Fill the column and left-align inside it, so a one-line
            // paragraph starts at the same left edge as a wrapped one rather
            // than centering itself in a frame its own width. A hugging
            // container sizes to its text instead, so a short message does
            // not stretch to reading measure.
            .frame(maxWidth: hugsContent ? nil : .infinity, alignment: .leading)
            .padding(.vertical, vertical ? dimensions.verticalPadding : 0)
            .frame(maxWidth: clampedWidth)
            // Outside the clamp, so the column width is the item's real
            // visual bound wherever the window can seat it. The padding only
            // takes space once the window is narrower than the column.
            .padding(.horizontal, edgePadding)
            // The column itself centers in whatever contains it.
            .frame(maxWidth: fillsContainer ? .infinity : nil, alignment: .center)
    }

    /// A hugging item takes no column — its container is already sized to it,
    /// so clamping here would only center the text in a box it doesn't fill.
    private var clampedWidth: CGFloat? {
        hugsContent ? nil : maxWidth
    }

    /// A hugging item has no column to center in — it is as wide as it is.
    private var fillsContainer: Bool { !hugsContent }

    private var maxWidth: CGFloat {
        bleed ? dimensions.bleedWidth : dimensions.contentWidth
    }

    /// A hugging item pays the bleed band too — its own container never
    /// clamps, so this is the only thing holding it off the edge.
    private var edgePadding: CGFloat {
        bleed || hugsContent
            ? dimensions.horizontalBleedPadding
            : dimensions.horizontalEdgePadding
    }
}

extension View {
    /// Gives this item its own column in a chat list. See `ListItemPadding`.
    func listItemPadding(bleed: Bool = false, vertical: Bool = true) -> some View {
        modifier(ListItemPadding(bleed: bleed, vertical: vertical))
    }

    /// Clamps text to reading measure inside a container that is itself
    /// wider. A card may take the bleed column, but the prose in it still
    /// wraps at the same measure as prose anywhere else.
    func chatTextColumn() -> some View {
        modifier(ChatTextColumn())
    }
}

private struct ChatTextColumn: ViewModifier, ThemedView {
    @Environment(\.theme) var theme

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: dimensions.contentWidth, alignment: .leading)
            // The clamped column then centers in the wider one holding it, so
            // a card's prose sits under the same axis as prose outside it.
            .frame(maxWidth: .infinity, alignment: .center)
    }
}
