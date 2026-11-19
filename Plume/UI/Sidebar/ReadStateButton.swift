import SwiftUI

/// The context-menu item that marks a task's tabs, or one tab, as read when
/// any is unread, and otherwise marks a finished turn unread again.
struct ReadStateButton: View {
    let tabIDs: [UUID]
    /// Tells the task row's item from the tab chip's in the control server.
    let label: String

    var body: some View {
        let item = ReadStateItem(tabIDs: tabIDs)
        if item.marksRead {
            Button(action: item.perform) { Label("Mark as Read", systemImage: "circle") }
                .plainMenuIcon()
                .plumeID(item.controlID, label: label)
        } else {
            Button(action: item.perform) { Label("Mark as Unread", systemImage: "circle.fill") }
                .plainMenuIcon()
                .plumeID(item.controlID, label: label)
                .disabled(!item.isEnabled)
        }
    }
}

extension View {
    /// Registers `ReadStateButton` for a context menu, which mounts it only
    /// while open.
    func plumeReadStateMenuItem(tabIDs: [UUID], label: String) -> some View {
        let item = ReadStateItem(tabIDs: tabIDs)
        return plumeMenuItem(item.controlID, label: label, isEnabled: item.isEnabled, invoke: item.perform)
    }
}

private struct ReadStateItem {
    let tabIDs: [UUID]
    let marksRead: Bool
    private let unreadTargets: [UUID]

    init(tabIDs: [UUID]) {
        self.tabIDs = tabIDs
        marksRead = UnreadStore.shared.hasUnread(among: tabIDs)
        if marksRead {
            unreadTargets = []
        } else {
            let statuses = Dictionary(
                tabIDs.map { ($0, StatusEngine.shared.status(forTab: $0)) },
                uniquingKeysWith: { first, _ in first }
            )
            unreadTargets = UnreadStore.shared.tabsToMarkUnread(statuses)
        }
    }

    var controlID: String { marksRead ? AccessibilityID.markReadButton : AccessibilityID.markUnreadButton }
    var isEnabled: Bool { marksRead || !unreadTargets.isEmpty }

    func perform() {
        guard marksRead else {
            UnreadStore.shared.markUnread(unreadTargets)
            return
        }
        UnreadStore.shared.markRead(tabIDs)
        for tabID in tabIDs {
            BellStore.shared.markSeen(tabID: tabID)
            Notifier.shared.dismiss(tabID: tabID)
        }
    }
}
