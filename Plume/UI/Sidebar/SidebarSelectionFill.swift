import SwiftUI

/// The selected sidebar row's fill, drawn by hand so it stays a dim wash
/// instead of the system accent.
///
/// `List(selection:)` would otherwise fill a selected row with the accent
/// color, which reads as bright blue over a `themeTint`ed sidebar. Taking the
/// row background over replaces that fill.
///
/// The wash does not change with focus: one selected appearance, whether or
/// not the sidebar is the active pane. `.tint` is not the seam for this — on a
/// sidebar list it recolors the row's accent *content*, not the rectangle.
struct SidebarSelectionFill: View {
    @Environment(\.colorScheme) private var colorScheme

    let isSelected: Bool

    /// The wash a selected row takes, light enough to keep the row's own text
    /// readable over it. Matches the tab chips in `TabStripView`.
    static func opacity(for colorScheme: ColorScheme) -> Double {
        Emphasis.backgroundTint.fillOpacity(for: colorScheme)
    }

    var body: some View {
        Color.chatSurface(.primary, colorScheme: colorScheme)
            .opacity(isSelected ? Self.opacity(for: colorScheme) : 0)
            .clipShape(.rect(cornerRadius: 6))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
    }
}
