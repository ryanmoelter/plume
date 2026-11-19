import Foundation

/// A click on a nested line also fires the row's own tap, in either order.
/// The row's tap chooses a tab on a later turn of the main queue, still in
/// the same frame, and skips that choice if a nested line handled the same
/// click.
@MainActor
enum TaskRowClick {
    private static var isClaimed = false

    /// The flag clears two turns of the main queue later, so a row tap that
    /// fires after the nested line still sees it, and an `invoke` alone never
    /// leaves it set.
    static func claim() {
        isClaimed = true
        DispatchQueue.main.async {
            DispatchQueue.main.async { isClaimed = false }
        }
    }

    static func rowClicked(_ task: WorkTask) {
        DispatchQueue.main.async {
            defer { isClaimed = false }
            guard !isClaimed else { return }
            TaskStore.selectRowClickTab(of: task)
        }
    }
}
