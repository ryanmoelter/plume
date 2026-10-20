import Foundation

/// The window's floor, and the column widths that decide it.
///
/// The two columns have independent minimums, so collapsing the sidebar lets
/// the window shrink by exactly what the sidebar was holding.
enum WindowMetrics {
    /// Enough for the add button, its menu, and the sidebar toggle.
    static let sidebarMinimumWidth: CGFloat = 221
    static let sidebarIdealWidth: CGFloat = 240

    static let paneMinimumWidth: CGFloat = 360

    static let minimumHeight: CGFloat = 420

    /// Every pane's floor plus the dividers between them, so the window
    /// grows when a split opens rather than squeezing a pane under its floor.
    static func detailMinimumWidth(paneCount: Int) -> CGFloat {
        let panes = max(paneCount, 1)
        return CGFloat(panes) * paneMinimumWidth + CGFloat(panes - 1) * SplitLayout.dividerWidth
    }

    /// `sidebarWidth` is the sidebar's current width.
    static func minimumWidth(
        sidebarVisible: Bool,
        paneCount: Int,
        sidebarWidth: CGFloat = sidebarMinimumWidth
    ) -> CGFloat {
        let detail = detailMinimumWidth(paneCount: paneCount)
        guard sidebarVisible else { return detail }
        return heldSidebarWidth(paneCount: paneCount, sidebarWidth: sidebarWidth) + detail
    }

    /// The sidebar's ceiling for a given window width, so dragging the
    /// divider can never squeeze the detail column below its own floor.
    /// Clamped to `sidebarMinimumWidth` regardless of how narrow the window
    /// gets.
    static func sidebarMaximumWidth(
        windowWidth: CGFloat,
        paneCount: Int,
        sidebarWidth: CGFloat = sidebarMinimumWidth
    ) -> CGFloat {
        max(
            heldSidebarWidth(paneCount: paneCount, sidebarWidth: sidebarWidth),
            windowWidth - detailMinimumWidth(paneCount: paneCount)
        )
    }

    /// A split grows the window around the sidebar rather than narrowing it,
    /// since the split view never widens a sidebar back once its ceiling has
    /// cut it down. Unsplit, the sidebar gives way as the window shrinks.
    private static func heldSidebarWidth(paneCount: Int, sidebarWidth: CGFloat) -> CGFloat {
        paneCount > 1 ? max(sidebarMinimumWidth, sidebarWidth) : sidebarMinimumWidth
    }
}
