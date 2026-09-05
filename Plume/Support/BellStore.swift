import Foundation
import Observation

/// Which tabs have rung a bell the user hasn't seen yet.
///
/// A bell is only worth marking when the user wasn't looking: a bell rung in
/// the tab on screen has already been heard, so it never leaves a dot. The
/// mark clears when the tab comes on screen, which includes the app coming
/// forward with that tab already selected.
///
/// In memory like every other live-process fact — a relaunch starts with no
/// unseen bells.
@MainActor
@Observable
final class BellStore {
    static let shared = BellStore()

    private(set) var unseenTabs: Set<UUID> = []

    init() {}

    func hasUnseenBell(tabID: UUID) -> Bool {
        unseenTabs.contains(tabID)
    }

    /// Records a bell. `isOnScreen` is the caller's answer to "was the user
    /// looking at this tab", so this type never has to know about selection.
    func recordBell(tabID: UUID, isOnScreen: Bool) {
        guard !isOnScreen else { return }
        unseenTabs.insert(tabID)
    }

    func markSeen(tabID: UUID) {
        unseenTabs.remove(tabID)
    }

    func forget(tabID: UUID) {
        unseenTabs.remove(tabID)
    }

    func reset() {
        unseenTabs.removeAll()
    }
}
