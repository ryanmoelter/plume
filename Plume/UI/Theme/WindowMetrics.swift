import Foundation

/// The window's floor, and the column widths that decide it.
///
/// The two columns have independent minimums, so collapsing the sidebar lets
/// the window shrink by exactly what the sidebar was holding.
enum WindowMetrics {
    /// Enough for the add button, its menu, and the sidebar toggle.
    static let sidebarMinimumWidth: CGFloat = 221
    static let sidebarIdealWidth: CGFloat = 240

    static let detailMinimumWidth: CGFloat = 360

    static let minimumHeight: CGFloat = 420

    static func minimumWidth(sidebarVisible: Bool) -> CGFloat {
        sidebarVisible ? sidebarMinimumWidth + detailMinimumWidth : detailMinimumWidth
    }
}
