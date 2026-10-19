import SwiftUI

/// The selected sidebar row's fill: a dim wash rather than the system
/// accent's solid fill, which reads as bright blue over a `themeTint`ed
/// sidebar.
///
/// The wash does not change with focus: one selected appearance, whether or
/// not the sidebar is the active pane.
///
/// The wash is the foreground until a palette accent is chosen, then that
/// accent — so the system-accent default keeps the neutral look.
struct SidebarSelectionFill: View {
    @Environment(\.colorScheme) private var colorScheme

    let isSelected: Bool

    /// The selected wash, shared with the selected tab chip in `TabStripView`.
    /// The accent takes the slash-command list's highlight strength: a hue at
    /// the foreground's wash strength reads as no selection at all.
    static func wash(for colorScheme: ColorScheme) -> Color {
        if AppSettings.shared.accentPaletteSlot != nil {
            ThemeChrome.accent(for: colorScheme)
                .opacity(Emphasis.divider.fillOpacity(for: colorScheme))
        } else {
            Color.chatSurface(.primary, colorScheme: colorScheme)
                .opacity(Emphasis.backgroundTint.fillOpacity(for: colorScheme))
        }
    }

    var body: some View {
        (isSelected ? Self.wash(for: colorScheme) : .clear)
            .clipShape(.rect(cornerRadius: SidebarMetrics.selectionCornerRadius))
    }
}
