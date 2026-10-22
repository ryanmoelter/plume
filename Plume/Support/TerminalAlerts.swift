import Foundation

/// Turns a terminal's bells and OSC 9 / OSC 777 requests into bell marks,
/// unread marks and system notifications.
///
/// Fed by `TerminalSession` rather than by its view, so a terminal in a task
/// that isn't selected — whose view is not mounted — still reaches the user.
@MainActor
final class TerminalAlerts {
    static let shared = TerminalAlerts()

    /// The task owning a tab. `MainWindow` installs it, keeping SwiftData out
    /// of here; nil means the tab is gone and the alert is dropped.
    var taskID: (UUID) -> UUID? = { _ in nil }

    private let notifier: Notifier
    private let bells: BellStore
    private let unread: UnreadStore

    init(notifier: Notifier = .shared, bells: BellStore = .shared, unread: UnreadStore = .shared) {
        self.notifier = notifier
        self.bells = bells
        self.unread = unread
    }

    struct BellResponse: Equatable {
        /// The tab chip's bell mark, cleared once the tab is on screen.
        var marksBell: Bool
        /// The task's unread dot, cleared only once the tab is focused.
        var marksUnread: Bool
        var notifies: Bool
    }

    /// A bell in the other pane of a split is on screen, so it is heard and
    /// not notified, but it stays unread until that pane is focused.
    static func response(toBellIn tabID: UUID, taskID: UUID, audience: NotificationAudience) -> BellResponse {
        let onScreen = NotificationSuppression.isOnScreen(tabID: tabID, taskID: taskID, audience: audience)
        return BellResponse(
            marksBell: !onScreen,
            marksUnread: !UnreadStore.isSeen(tabID: tabID, taskID: taskID, audience: audience),
            notifies: !onScreen
        )
    }

    func bellRang(in session: TerminalSession) {
        let tabID = session.id
        guard let taskID = taskID(tabID) else { return }
        let response = Self.response(toBellIn: tabID, taskID: taskID, audience: notifier.audience())
        bells.recordBell(tabID: tabID, isOnScreen: !response.marksBell)
        if response.marksUnread { unread.markUnread([tabID]) }
        guard response.notifies else { return }
        notifier.post(.init(
            taskID: taskID,
            tabID: tabID,
            title: TitleStore.shared.title(forTab: tabID) ?? session.displayTitle,
            body: "The terminal rang a bell.",
            dedupeKey: Notifier.dedupeKey(.bell, tabID: tabID)
        ))
    }

    /// The program named its own title and body, so this skips the bell's
    /// marks — but it is still redundant when the user is watching.
    func desktopNotificationArrived(_ notification: TerminalSession.DesktopNotification, in session: TerminalSession) {
        let tabID = session.id
        guard let taskID = taskID(tabID) else { return }
        notifier.notifyIfUnseen(.init(
            taskID: taskID,
            tabID: tabID,
            title: notification.title.isEmpty ? session.displayTitle : notification.title,
            body: notification.body,
            dedupeKey: Notifier.dedupeKey(.osc, tabID: tabID)
        ))
    }
}
