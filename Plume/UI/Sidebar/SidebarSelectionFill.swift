import SwiftUI

/// The selected sidebar row's fill: a dim wash rather than the system
/// accent's solid fill, which reads as bright blue over a `themeTint`ed
/// sidebar.
///
/// The wash does not change with the sidebar's focus, only with the
/// window's: an inactive window draws it in the text color.
struct SidebarSelectionFill: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appearsActive) private var appearsActive

    let isSelected: Bool
    var tint: Color?

    /// The selected wash, shared with the selected tab chip in `TabStripView`.
    /// The accent takes the slash-command list's highlight strength: a hue at
    /// the foreground's wash strength reads as no selection at all.
    static func wash(for colorScheme: ColorScheme, isActive: Bool, tint: Color? = nil) -> Color {
        if isActive {
            (tint ?? ThemeChrome.accent(for: colorScheme))
                .opacity(Emphasis.divider.fillOpacity(for: colorScheme))
        } else {
            Color.chatSurface(.primary, colorScheme: colorScheme)
                .opacity(Emphasis.backgroundTint.fillOpacity(for: colorScheme))
        }
    }

    var body: some View {
        (isSelected ? Self.wash(for: colorScheme, isActive: appearsActive, tint: tint) : .clear)
            .clipShape(.rect(cornerRadius: SidebarMetrics.selectionCornerRadius))
    }
}
