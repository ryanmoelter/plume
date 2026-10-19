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

    /// The wash a selected row takes, light enough to keep the row's own text
    /// readable over it. Matches the tab chips in `TabStripView`.
    static func opacity(for colorScheme: ColorScheme) -> Double {
        Emphasis.backgroundTint.fillOpacity(for: colorScheme)
    }

    var body: some View {
        fill
            .opacity(isSelected ? fillOpacity : 0)
            .clipShape(.rect(cornerRadius: SidebarMetrics.selectionCornerRadius))
    }

    private var usesAccent: Bool { AppSettings.shared.accentPaletteSlot != nil }

    private var fill: Color {
        usesAccent
            ? ThemeChrome.accent(for: colorScheme)
            : Color.chatSurface(.primary, colorScheme: colorScheme)
    }

    /// The accent takes the slash-command list's highlight strength: a hue
    /// at the foreground's wash strength reads as no selection at all.
    private var fillOpacity: Double {
        usesAccent ? Emphasis.divider.fillOpacity(for: colorScheme) : Self.opacity(for: colorScheme)
    }
}
