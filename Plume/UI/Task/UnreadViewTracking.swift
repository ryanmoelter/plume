import AppKit
import SwiftUI

extension View {
    /// Clears the unread mark of the tab on screen: when it is selected, and
    /// when the app comes forward with it already selected.
    func clearsUnreadOnView(selectedTabID: UUID?) -> some View {
        onChange(of: selectedTabID, initial: true) { _, _ in
            UnreadStore.shared.markViewed(Notifier.shared.audience())
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            UnreadStore.shared.markViewed(Notifier.shared.audience())
        }
    }
}
