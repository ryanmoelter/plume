import AppKit
import SwiftUI

extension View {
    /// Clears the unread marks of `task`'s on-screen tabs: when they come on
    /// screen, and when the app comes forward with them already showing.
    func clearsUnreadOnView(of task: WorkTask?) -> some View {
        modifier(ClearsUnreadOnView(task: task))
    }
}

/// A modifier of its own so only it, not the window around it, depends on
/// the task's panes.
private struct ClearsUnreadOnView: ViewModifier {
    let task: WorkTask?

    func body(content: Content) -> some View {
        content
            .onChange(of: task?.paneTabIDs ?? [], initial: true) { _, _ in
                UnreadStore.shared.markViewed(Notifier.shared.audience())
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                UnreadStore.shared.markViewed(Notifier.shared.audience())
            }
    }
}
