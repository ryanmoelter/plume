import Foundation

/// Which sidebar entry an arrow key moves the selection to.
///
/// Kept out of `SidebarView` so it is testable without SwiftData: the view's
/// task lists come from `@Query`. The list's own selection used to provide
/// this, but the rows disable it so the selection fill can be drawn by hand.
enum SidebarKeyboardNavigation {
    /// Home, then every task in the order the sidebar shows them.
    static func entries(taskIDs: [UUID]) -> [SidebarSelection] {
        [.home] + taskIDs.map(SidebarSelection.task)
    }

    /// The entry to select after moving `offset` rows, or `nil` to stay put.
    ///
    /// With nothing selected, an arrow key selects the first entry — the same
    /// thing `List` did.
    static func destination<ID: Equatable>(
        from selection: ID?,
        in ordered: [ID],
        offset: Int
    ) -> ID? {
        guard !ordered.isEmpty else { return nil }
        guard let selection, let index = ordered.firstIndex(of: selection) else {
            return ordered.first
        }
        let next = index + offset
        guard ordered.indices.contains(next) else { return nil }
        return ordered[next]
    }
}
