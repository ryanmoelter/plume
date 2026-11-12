import SwiftUI

/// The label of a menu laid over a pane row, such as a row's `…`.
/// `.menuStyle(.button)` lets the menu take `foregroundStyle`, but it sizes
/// the label to the bare glyph. The font and height here match the borderless
/// popup button the glyph sat in before, so it keeps its size and its place
/// under the open icon. The label carries the wash, so the whole washed rect
/// opens the menu; follow the menu with `.padding(-OverlaidControlWash.inset)`.
struct RowMenuLabel: View {
    static let height: CGFloat = 16

    var systemImage = "ellipsis"
    /// Centers the glyph on a line taller than its own.
    var lineHeight: CGFloat?
    let isHovering: Bool

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: NSFont.systemFontSize, weight: .medium))
            .frame(width: InfoPaneLayout.iconColumnWidth, height: lineHeight ?? Self.height)
            .modifier(OverlaidControlWash(isHovering: isHovering))
    }
}
