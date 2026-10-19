import AppKit
import SwiftUI

extension View {
    /// Clears the unread marks of the tabs on screen: when they come on
    /// screen, and when the app comes forward with them already showing.
    func clearsUnreadOnView(onScreenTabIDs: [UUID]) -> some View {
        onChange(of: onScreenTabIDs, initial: true) { _, _ in
            UnreadStore.shared.markViewed(Notifier.shared.audience())
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            UnreadStore.shared.markViewed(Notifier.shared.audience())
        }
    }
}
