import Testing
import Foundation
@testable import Plume

/// `forget` is `GitStateStore`'s side of the teardown `PullRequestStore`
/// already had — dropping a directory's watch whatever its refcount, for a
/// task deleted out from under the row (or the startup warm pass) that took
/// it. Without it a deleted task's directory kept its poll and its `.git`
/// `FileWatcher` running forever.
@MainActor
struct GitStateStoreForgetTests {
    @Test func forgetDropsTheWatchEvenWithMultipleReferences() {
        let store = GitStateStore()
        defer { store.reset() }

        store.watch("/repo/task")
        store.watch("/repo/task") // a second reference, e.g. the warm pass and a row both

        store.forget(directory: "/repo/task")

        // Watching again afterwards should start fresh rather than resume a
        // stale refcount, which would need a matching number of `release`s
        // that no longer exist.
        store.watch("/repo/task")
        store.release("/repo/task")
    }

    @Test func forgetDropsTheLastKnownState() {
        let store = GitStateStore()
        defer { store.reset() }

        store.seedFixture(directory: "/repo/task", state: GitState(
            branch: "main", upstream: "origin/main", ahead: 0, behind: 0, isDirty: false
        ))
        store.watch("/repo/task")
        store.release("/repo/task")
        // Released but not forgotten: the last answer survives so a remounted
        // row renders immediately.
        #expect(store.state(for: "/repo/task")?.branch == "main")

        store.forget(directory: "/repo/task")

        #expect(store.state(for: "/repo/task") == nil)
    }
}
