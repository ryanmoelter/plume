import SwiftUI

/// The context-menu item that marks a task's tabs, or one tab, as read when
/// any is unread, and otherwise marks a finished turn unread again.
struct ReadStateButton: View {
    let tabIDs: [UUID]
    /// Tells the task row's item from the tab chip's in the control server.
    let label: String

    var body: some View {
        if UnreadStore.shared.hasUnread(among: tabIDs) {
            Button { markRead() } label: { Label("Mark as Read", systemImage: "circle") }
                .plumeID(AccessibilityID.markReadButton, label: label)
        } else {
            let statuses = Dictionary(
                tabIDs.map { ($0, StatusEngine.shared.status(forTab: $0)) },
                uniquingKeysWith: { first, _ in first }
            )
            let targets = UnreadStore.shared.tabsToMarkUnread(statuses)
            Button { UnreadStore.shared.markUnread(targets) } label: { Label("Mark as Unread", systemImage: "circle.fill") }
                .plumeID(AccessibilityID.markUnreadButton, label: label)
                .disabled(targets.isEmpty)
        }
    }

    private func markRead() {
        UnreadStore.shared.markRead(tabIDs)
        for tabID in tabIDs {
            BellStore.shared.markSeen(tabID: tabID)
            Notifier.shared.dismiss(tabID: tabID)
        }
    }
}
