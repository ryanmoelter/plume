import Foundation

/// A click on a nested line also fires the row's own tap, in no promised
/// order. The nested line claims the click; the row decides its tab one main
/// queue hop later, still in the same frame, and yields to a claim.
@MainActor
enum TaskRowClick {
    private static var isClaimed = false

    /// The claim lapses after two hops, so a row tap enqueued after it in the
    /// same event still sees it, and an `invoke` alone never leaves it set.
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
