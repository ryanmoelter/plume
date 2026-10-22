import Foundation
import Observation

/// Which tabs finished a turn the user hasn't looked at yet.
///
/// Fed the effective status `StatusEngine` reports, so a turn that ends while
/// its subagents still work is not unread until they stop. A turn that ends
/// in the focused tab has already been seen and leaves no mark. The other
/// pane of a split is on screen, so it is not notified, but it stays unread
/// until it is focused. Any later status replaces the mark, because that
/// status is now what the tab has to say.
///
/// In memory like `BellStore` — a relaunch starts with nothing unread.
@MainActor
@Observable
final class UnreadStore {
    static let shared = UnreadStore()

    private(set) var unreadTabs: Set<UUID> = []

    /// The order tabs' current turns finished in, so Mark as Unread on a task
    /// can pick the latest.
    @ObservationIgnored private var finishOrder: [UUID: Int] = [:]
    @ObservationIgnored private var finishCount = 0

    init() {}

    func observe(_ engine: StatusEngine, audience: @escaping () -> NotificationAudience) {
        engine.setTabStatusObserver("UnreadStore") { [weak self] taskID, tabID, status, _ in
            let seen = Self.isSeen(tabID: tabID, taskID: taskID, audience: audience())
            self?.record(status, tabID: tabID, isSeen: seen)
        }
    }

    func isUnread(tabID: UUID) -> Bool {
        unreadTabs.contains(tabID)
    }

    func hasUnread(among tabIDs: some Sequence<UUID>) -> Bool {
        tabIDs.contains { unreadTabs.contains($0) }
    }

    func record(_ status: TaskStatus, tabID: UUID, isSeen: Bool) {
        if status == .awaitingReply {
            finishCount += 1
            finishOrder[tabID] = finishCount
        } else {
            finishOrder.removeValue(forKey: tabID)
        }
        if status == .awaitingReply, !isSeen {
            unreadTabs.insert(tabID)
        } else {
            unreadTabs.remove(tabID)
        }
    }

    /// The tabs Mark as Unread marks, given the statuses of a task's tabs, or
    /// of one tab. Empty — and the menu item disabled — unless every turn has
    /// finished and none is unread already. Of a task's read tabs, only the
    /// one that finished last is marked; when no tab has a recorded finish,
    /// all of them are.
    func tabsToMarkUnread(_ statuses: [UUID: TaskStatus]) -> [UUID] {
        guard TaskStatus.aggregate(statuses.values) == .awaitingReply,
              !hasUnread(among: statuses.keys)
        else { return [] }
        let finished = statuses.filter { $0.value == .awaitingReply }.map(\.key)
        let latest = finished.compactMap { id in finishOrder[id].map { (id, $0) } }.max { $0.1 < $1.1 }
        return latest.map { [$0.0] } ?? finished
    }

    /// Survives the tab staying in view: the mark clears only on the next
    /// `markViewed`, which runs when focus moves, the app comes forward, or
    /// the focused tab is selected again.
    func markUnread(_ tabIDs: some Sequence<UUID>) {
        unreadTabs.formUnion(tabIDs)
    }

    func markRead(_ tabIDs: some Sequence<UUID>) {
        unreadTabs.subtract(tabIDs)
    }

    /// Clears the focused tab, the only one the user is reading.
    func markViewed(_ audience: NotificationAudience) {
        guard audience.isAppActive, let focused = audience.focusedTabID else { return }
        unreadTabs.remove(focused)
    }

    static func isSeen(tabID: UUID, taskID: UUID, audience: NotificationAudience) -> Bool {
        audience.isAppActive
            && audience.selectedTaskID == taskID
            && audience.focusedTabID == tabID
    }

    func forget(tabID: UUID) {
        unreadTabs.remove(tabID)
        finishOrder.removeValue(forKey: tabID)
    }

    func reset() {
        unreadTabs.removeAll()
        finishOrder.removeAll()
    }

    /// Whether a task's badge shows the unread dot. A tab that wants the user
    /// outranks it, since that is something to act on rather than to read.
    static func showsUnread(taskStatus: TaskStatus, hasUnreadTab: Bool) -> Bool {
        hasUnreadTab && !taskStatus.wantsAttention
    }
}
