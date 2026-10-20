import AppKit
import SwiftUI

extension View {
    /// Clears the unread mark of `task`'s focused tab: when it takes focus,
    /// and when the app comes forward with it already focused.
    func clearsUnreadOnView(of task: WorkTask?) -> some View {
        modifier(ClearsUnreadOnView(task: task))
    }
}

/// A modifier of its own so only it, not the window around it, depends on
/// the task's focused tab.
private struct ClearsUnreadOnView: ViewModifier {
    let task: WorkTask?

    func body(content: Content) -> some View {
        content
            .onChange(of: task?.selectedTabID, initial: true) { _, _ in
                UnreadStore.shared.markViewed(Notifier.shared.audience())
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                UnreadStore.shared.markViewed(Notifier.shared.audience())
            }
    }
}
