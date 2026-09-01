import SwiftUI

/// The selected row's background, drawn by hand so it dims rather than
/// painting the system accent.
///
/// `List(selection:)` otherwise fills the row with the accent color, which
/// reads as bright blue over a `themeTint`ed sidebar. This is the same wash
/// `TabStripView` uses for tab chips: the theme's own foreground at low
/// opacity, falling back to `.selection` when no theme is configured.
///
/// Taking the background over costs the row its automatic label inversion,
/// so the label keeps its ordinary color over the wash. That stays legible
/// because the wash tints toward the *same* foreground the label uses, so it
/// can only move partway from the background toward the label, never past
/// it. Measured against the Lum theme, 0.22 leaves 7.7:1 in dark and 6.2:1
/// in light. A theme whose own foreground and background barely contrast
/// (Solarized, around 4:1) inherits that narrowness here too.
struct SidebarSelectionBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    let isSelected: Bool

    var body: some View {
        Group {
            if let themeForeground = ThemeChrome.foreground(for: colorScheme) {
                themeForeground.opacity(isSelected ? 0.22 : 0)
            } else if isSelected {
                Color.clear.background(.selection)
            } else {
                Color.clear
            }
        }
        .clipShape(.rect(cornerRadius: 6))
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
    }
}
