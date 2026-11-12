import SwiftUI

/// The label of a menu laid over a pane row, such as a row's `…`.
/// `.menuStyle(.button)` sizes the label to the bare glyph, so the label sets
/// an explicit font and height to keep the glyph's size and place. The label
/// carries the wash, so the whole washed rect opens the menu; follow the menu
/// with `.padding(-OverlaidControlWash.inset)`.
struct RowMenuLabel: View {
    static let height: CGFloat = 16

    /// Centers the glyph on a line taller than its own.
    var lineHeight: CGFloat?
    let isHovering: Bool

    var body: some View {
        Image(systemName: "ellipsis")
            .font(.system(size: NSFont.systemFontSize, weight: .medium))
            .frame(width: InfoPaneLayout.iconColumnWidth, height: lineHeight ?? Self.height)
            .modifier(OverlaidControlWash(isHovering: isHovering))
    }
}
