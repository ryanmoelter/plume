import Foundation

/// Which tabs the user is actually looking at, and so which alerts are
/// redundant.
struct NotificationAudience: Equatable {
    /// Whether Plume is the frontmost application.
    var isAppActive: Bool
    /// The task shown in the detail pane, if any.
    var selectedTaskID: UUID?
    /// The tabs on screen within that task — two while it is split.
    var onScreenTabIDs: Set<UUID> = []
    /// The on-screen tab that has focus. In a split, the other pane is on
    /// screen without having been read.
    var focusedTabID: UUID?

    static let inactive = NotificationAudience(isAppActive: false)
}

/// Decides whether an event deserves a system notification.
///
/// The rule is "notify unless the user already saw it": a tab that is on
/// screen in the frontmost window has already shown the bell or the prompt,
/// so an alert about it is noise. Everything else notifies — a background
/// tab, a background task, or any tab at all while Plume is not frontmost.
enum NotificationSuppression {
    static func shouldNotify(tabID: UUID, taskID: UUID, audience: NotificationAudience) -> Bool {
        !isOnScreen(tabID: tabID, taskID: taskID, audience: audience)
    }

    static func isOnScreen(tabID: UUID, taskID: UUID, audience: NotificationAudience) -> Bool {
        audience.isAppActive
            && audience.selectedTaskID == taskID
            && audience.onScreenTabIDs.contains(tabID)
    }
}
