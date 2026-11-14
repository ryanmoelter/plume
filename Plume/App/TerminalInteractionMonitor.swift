import AppKit

/// Clears the focused terminal's unread mark when the user interacts with it:
/// a keypress, click, scroll or drag-selection inside its view.
@MainActor
final class TerminalInteractionMonitor {
    static let shared = TerminalInteractionMonitor()

    private var monitor: Any?

    private init() {}

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]
        ) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    private func handle(_ event: NSEvent) {
        let unread = UnreadStore.shared
        guard !unread.unreadTabs.isEmpty,
              let focused = Notifier.shared.audience().focusedTabID,
              unread.isUnread(tabID: focused),
              SurfaceManager.shared.existingSession(for: focused)?.isTarget(of: event) == true
        else { return }
        unread.markRead([focused])
    }
}
