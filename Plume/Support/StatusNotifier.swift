import Foundation

/// Turns agent status changes into system notifications.
///
/// Hooks `StatusEngine`, which both transports report through, so this holds
/// no opinion about how the agent runs.
@MainActor
final class StatusNotifier {
    private let notifier: Notifier
    /// Resolves a tab's display name at post time. `MainWindow` supplies it,
    /// keeping SwiftData out of here.
    private let tabTitle: (UUID) -> String

    init(
        engine: StatusEngine = .shared,
        notifier: Notifier = .shared,
        tabTitle: @escaping (UUID) -> String
    ) {
        self.notifier = notifier
        self.tabTitle = tabTitle

        engine.onTabStatusChanged = { [weak self] taskID, tabID, status, notifiable in
            guard notifiable else { return }
            self?.handle(taskID: taskID, tabID: tabID, status: status)
        }
    }

    private func handle(taskID: UUID, tabID: UUID, status: TaskStatus) {
        guard let body = Self.body(for: status, notifiesOnTurnEnd: AppSettings.shared.notifiesOnTurnEnd) else { return }
        notifier.notifyIfUnseen(.init(
            taskID: taskID,
            tabID: tabID,
            title: tabTitle(tabID),
            body: body,
            // One entry per tab: a tab that finishes, waits, then finishes
            // again should leave the latest state, not a stack of them.
            dedupeKey: "status-\(tabID.uuidString)"
        ))
    }

    /// Nil means the status isn't worth interrupting for. Every state that
    /// wants the user says what it wants, so the notification is worth acting
    /// on rather than just worth reading.
    ///
    /// A finished turn is the one judgement call: it happens every time the
    /// agent stops talking, which is far too often to interrupt over by
    /// default, so it notifies only when asked to.
    nonisolated static func body(for status: TaskStatus, notifiesOnTurnEnd: Bool) -> String? {
        switch status {
        case .planApproval: "A plan is waiting for your approval."
        case .questionAsked: "The agent asked you a question."
        case .permissionNeeded: "A tool is waiting for your approval."
        case .needsTerminalInput: "Waiting for your input."
        case .error: "The agent stopped unexpectedly."
        case .awaitingReply: notifiesOnTurnEnd ? "It's your turn." : nil
        // Starting and working are transitions the user asked for, and an
        // interruption is the user's own doing, so it needs no telling. A
        // subagent finishing is one step inside a turn the chat already shows,
        // and several can land in a row.
        case .working, .notStarted, .interrupted, .done: nil
        }
    }
}
