import SwiftUI

/// The measured widths the window's floor and the sidebar's ceiling are
/// derived from.
@Observable
final class WindowColumnWidths {
    /// Starts generous so the sidebar's ceiling is unclamped until the first
    /// real measurement lands.
    var window: CGFloat = .infinity
    var sidebar: CGFloat = WindowMetrics.sidebarIdealWidth
}

/// The window's minimum size for the selected task. A modifier of its own so
/// only it, not the window's root, depends on the task's panes.
struct WindowFloor: ViewModifier {
    let task: WorkTask?
    let sidebarVisible: Bool
    let widths: WindowColumnWidths

    func body(content: Content) -> some View {
        content.frame(
            minWidth: WindowMetrics.minimumWidth(
                sidebarVisible: sidebarVisible,
                paneCount: task?.paneCount ?? 1,
                sidebarWidth: widths.sidebar
            ),
            minHeight: WindowMetrics.minimumHeight
        )
    }
}

/// The sidebar column's width bounds, measuring the width it ends up at.
struct SidebarColumnWidth: ViewModifier {
    let task: WorkTask?
    let widths: WindowColumnWidths

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                // A collapsed sidebar measures nothing; keep the width it
                // comes back at.
                if width > 0 { widths.sidebar = width }
            }
            .navigationSplitViewColumnWidth(
                min: WindowMetrics.sidebarMinimumWidth,
                ideal: WindowMetrics.sidebarIdealWidth,
                max: WindowMetrics.sidebarMaximumWidth(
                    windowWidth: widths.window,
                    paneCount: task?.paneCount ?? 1,
                    sidebarWidth: widths.sidebar
                )
            )
    }
}
