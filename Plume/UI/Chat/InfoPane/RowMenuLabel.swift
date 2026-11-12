import SwiftUI

/// The `…` on a row's actions menu. `.menuStyle(.button)` lets the menu take
/// `foregroundStyle`, but it sizes the label to the bare glyph. The font and
/// height here match the borderless popup button the dots sat in before, so
/// they keep their size and their place under the open icon.
struct RowMenuLabel: View {
    static let height: CGFloat = 16

    var body: some View {
        Image(systemName: "ellipsis")
            .font(.system(size: NSFont.systemFontSize, weight: .medium))
            .frame(height: Self.height)
    }
}
