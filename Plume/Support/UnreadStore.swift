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
/// A chat tab's mark survives a relaunch, stored as the ID of the
/// conversation's latest message when it was set. `onStoredMarkChanged`
/// reports what to store, and `restore(tabID:messageID:)` brings a stored mark
/// back. A restored mark is kept only while the tab's latest message is still
/// that one: the transcript is the source of truth, so a conversation that
/// moved on while Plume was closed reads as read. Other tabs' marks stay in
/// memory, like `BellStore`.
@MainActor
@Observable
final class UnreadStore {
    static let shared = UnreadStore()

    private(set) var unreadTabs: Set<UUID> = []

    /// The order tabs' current turns finished in, so Mark as Unread on a task
    /// can pick the latest.
    @ObservationIgnored private var finishOrder: [UUID: Int] = [:]
    @ObservationIgnored private var finishCount = 0

    /// The message ID to store for a tab's mark, or nil to clear it.
    @ObservationIgnored var onStoredMarkChanged: ((UUID, String?) -> Void)?
    @ObservationIgnored private var latestMessageIDs: [UUID: String] = [:]
    /// Stored marks waiting for the tab's transcript to confirm them.
    @ObservationIgnored private var pendingRestores: [UUID: String] = [:]
    /// Restored marks, each pinned to the message it was set on. A mark set
    /// this launch instead follows the transcript, which can land after the
    /// turn's status does.
    @ObservationIgnored private var restoredMarks: [UUID: String] = [:]

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
        // A dormant tab settles to `notStarted` at launch, which says nothing
        // new about the conversation.
        if status == .notStarted, pendingRestores[tabID] != nil || restoredMarks[tabID] != nil { return }
        setUnread(status == .awaitingReply && !isSeen, tabID: tabID)
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
        for tabID in tabIDs { setUnread(true, tabID: tabID) }
    }

    func markRead(_ tabIDs: some Sequence<UUID>) {
        for tabID in tabIDs { setUnread(false, tabID: tabID) }
    }

    /// Clears the focused tab, the only one the user is reading.
    func markViewed(_ audience: NotificationAudience) {
        guard audience.isAppActive, let focused = audience.focusedTabID else { return }
        setUnread(false, tabID: focused)
    }

    /// Brings back a mark stored by an earlier launch. It shows once
    /// `latestMessageChanged` confirms the tab's latest message is still
    /// `messageID`.
    func restore(tabID: UUID, messageID: String) {
        guard !unreadTabs.contains(tabID) else { return }
        if latestMessageIDs[tabID] != nil {
            confirm(tabID: tabID, storedMessageID: messageID)
        } else {
            pendingRestores[tabID] = messageID
        }
    }

    func isAwaitingRestore(tabID: UUID) -> Bool {
        pendingRestores[tabID] != nil
    }

    func latestMessageChanged(tabID: UUID, to messageID: String?) {
        latestMessageIDs[tabID] = messageID
        if let stored = pendingRestores.removeValue(forKey: tabID) {
            confirm(tabID: tabID, storedMessageID: stored)
        } else if let pinned = restoredMarks[tabID] {
            if messageID != pinned { setUnread(false, tabID: tabID) }
        } else if unreadTabs.contains(tabID), let messageID {
            onStoredMarkChanged?(tabID, messageID)
        }
    }

    private func confirm(tabID: UUID, storedMessageID: String) {
        if latestMessageIDs[tabID] == storedMessageID {
            unreadTabs.insert(tabID)
            restoredMarks[tabID] = storedMessageID
        } else {
            onStoredMarkChanged?(tabID, nil)
        }
    }

    /// Anything that sets or clears a mark also settles a restore still
    /// waiting on its transcript, so the restore cannot revive a mark the
    /// user has since cleared.
    private func setUnread(_ unread: Bool, tabID: UUID) {
        let wasPending = pendingRestores.removeValue(forKey: tabID) != nil
        let changed = unread ? unreadTabs.insert(tabID).inserted : unreadTabs.remove(tabID) != nil
        guard changed || wasPending else { return }
        restoredMarks.removeValue(forKey: tabID)
        onStoredMarkChanged?(tabID, unread ? latestMessageIDs[tabID] : nil)
    }

    static func isSeen(tabID: UUID, taskID: UUID, audience: NotificationAudience) -> Bool {
        audience.isAppActive
            && audience.selectedTaskID == taskID
            && audience.focusedTabID == tabID
    }

    func forget(tabID: UUID) {
        unreadTabs.remove(tabID)
        finishOrder.removeValue(forKey: tabID)
        latestMessageIDs.removeValue(forKey: tabID)
        pendingRestores.removeValue(forKey: tabID)
        restoredMarks.removeValue(forKey: tabID)
    }

    func reset() {
        unreadTabs.removeAll()
        finishOrder.removeAll()
        latestMessageIDs.removeAll()
        pendingRestores.removeAll()
        restoredMarks.removeAll()
    }

    /// Whether a task's badge shows the unread dot. A tab that wants the user
    /// outranks it, since that is something to act on rather than to read.
    static func showsUnread(taskStatus: TaskStatus, hasUnreadTab: Bool) -> Bool {
        hasUnreadTab && !taskStatus.wantsAttention
    }
}
