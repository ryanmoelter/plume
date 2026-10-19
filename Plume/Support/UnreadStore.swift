import Foundation
import Observation

/// Which tabs finished a turn the user hasn't looked at yet.
///
/// Fed the effective status `StatusEngine` reports, so a turn that ends while
/// its subagents still work is not unread until they stop. A turn that ends
/// on screen has already been seen and leaves no mark; any later status
/// replaces the mark, because that status is now what the tab has to say.
///
/// In memory like `BellStore` — a relaunch starts with nothing unread.
@MainActor
@Observable
final class UnreadStore {
    static let shared = UnreadStore()

    private(set) var unreadTabs: Set<UUID> = []

    init() {}

    func observe(_ engine: StatusEngine, audience: @escaping () -> NotificationAudience) {
        engine.setTabStatusObserver("UnreadStore") { [weak self] taskID, tabID, status, _ in
            let onScreen = NotificationSuppression.isOnScreen(tabID: tabID, taskID: taskID, audience: audience())
            self?.record(status, tabID: tabID, isOnScreen: onScreen)
        }
    }

    func isUnread(tabID: UUID) -> Bool {
        unreadTabs.contains(tabID)
    }

    func hasUnread(among tabIDs: some Sequence<UUID>) -> Bool {
        tabIDs.contains { unreadTabs.contains($0) }
    }

    func record(_ status: TaskStatus, tabID: UUID, isOnScreen: Bool) {
        if status == .awaitingReply, !isOnScreen {
            unreadTabs.insert(tabID)
        } else {
            unreadTabs.remove(tabID)
        }
    }

    /// Clears whichever tabs the user is looking at now — both panes of a
    /// split task.
    func markViewed(_ audience: NotificationAudience) {
        guard audience.isAppActive else { return }
        unreadTabs.subtract(audience.onScreenTabIDs)
    }

    func forget(tabID: UUID) {
        unreadTabs.remove(tabID)
    }

    func reset() {
        unreadTabs.removeAll()
    }

    /// Whether a task's badge shows the unread dot. A tab that wants the user
    /// outranks it, since that is something to act on rather than to read.
    static func showsUnread(taskStatus: TaskStatus, hasUnreadTab: Bool) -> Bool {
        hasUnreadTab && !taskStatus.wantsAttention
    }
}
