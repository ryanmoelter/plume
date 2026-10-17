import Foundation

/// Which task Next Task and Previous Task move the sidebar selection to.
///
/// Kept out of `MainWindow` so it is testable without SwiftData: the task
/// lists come from `@Query`.
enum SidebarKeyboardNavigation {
    /// The id to select after moving `offset` rows, or `nil` to stay put.
    ///
    /// With nothing selected, an arrow key selects the first task — the same
    /// thing `List` did.
    static func destination(
        from selection: UUID?,
        in ordered: [UUID],
        offset: Int
    ) -> UUID? {
        guard !ordered.isEmpty else { return nil }
        guard let selection, let index = ordered.firstIndex(of: selection) else {
            return ordered.first
        }
        let next = index + offset
        guard ordered.indices.contains(next) else { return nil }
        return ordered[next]
    }
}
