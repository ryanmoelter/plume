import SwiftUI

/// The context-menu item that marks a finished turn unread again, for a
/// task's tabs or for one tab.
struct MarkAsUnreadButton: View {
    let tabIDs: [UUID]
    /// Tells the task row's item from the tab chip's in the control server.
    let label: String

    var body: some View {
        let statuses = Dictionary(
            tabIDs.map { ($0, StatusEngine.shared.status(forTab: $0)) },
            uniquingKeysWith: { first, _ in first }
        )
        let targets = UnreadStore.shared.tabsToMarkUnread(statuses)
        Button("Mark as Unread") { UnreadStore.shared.markUnread(targets) }
            .plumeID(AccessibilityID.markUnreadButton, label: label)
            .disabled(targets.isEmpty)
    }
}
