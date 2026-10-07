import Testing
import Foundation
import Observation
@testable import Plume

/// Every sidebar row and chat tab reads `state(for:)`, so a write that leaves
/// the answer unchanged must not invalidate them. Fixtures stand in for real
/// repositories so no `git` call races the assertions.
@MainActor
struct GitStateStoreObservationTests {
    private static let main = GitState(branch: "main", upstream: "origin/main", ahead: 0, behind: 0, isDirty: false)

    private func changes(in store: GitStateStore, reading directory: String, during work: () -> Void) -> Int {
        var count = 0
        withObservationTracking {
            _ = store.state(for: directory)
        } onChange: {
            count += 1
        }
        work()
        return count
    }

    @Test func refcountChangesDoNotInvalidateReaders() {
        let store = GitStateStore()
        defer { store.reset() }
        store.seedFixture(directory: "/repo/a", state: Self.main)
        store.seedFixture(directory: "/repo/b", state: Self.main)
        store.watch("/repo/a")
        store.watch("/repo/b")
        store.release("/repo/b")

        let count = changes(in: store, reading: "/repo/a") {
            store.watch("/repo/a")
            store.release("/repo/a")
            store.watch("/repo/b")
            store.release("/repo/b")
        }
        #expect(count == 0)
    }

    @Test func releasingTheLastReferenceDoesNotInvalidateReaders() {
        let store = GitStateStore()
        defer { store.reset() }
        store.seedFixture(directory: "/repo/a", state: Self.main)
        store.watch("/repo/a")

        let count = changes(in: store, reading: "/repo/a") {
            store.release("/repo/a")
            store.watch("/repo/a")
        }
        #expect(count == 0)
    }

    @Test func anUnchangedAnswerIsNotRepublished() {
        let store = GitStateStore()
        defer { store.reset() }
        store.seedFixture(directory: "/repo/a", state: Self.main)
        store.watch("/repo/a")

        let count = changes(in: store, reading: "/repo/a") {
            store.seedFixture(directory: "/repo/a", state: Self.main)
        }
        #expect(count == 0)
    }

    /// Guards the three tests above against passing because tracking saw nothing.
    @Test func aChangedAnswerStillInvalidatesReaders() {
        let store = GitStateStore()
        defer { store.reset() }
        store.seedFixture(directory: "/repo/a", state: Self.main)
        store.watch("/repo/a")

        let dirty = GitState(branch: "main", upstream: "origin/main", ahead: 0, behind: 0, isDirty: true)
        let count = changes(in: store, reading: "/repo/a") {
            store.seedFixture(directory: "/repo/a", state: dirty)
        }
        #expect(count == 1)
    }
}
