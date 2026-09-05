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

        engine.onTabStatusChanged = { [weak self] taskID, tabID, status in
            self?.handle(taskID: taskID, tabID: tabID, status: status)
        }
    }

    private func handle(taskID: UUID, tabID: UUID, status: TaskStatus) {
        guard let body = Self.body(for: status) else { return }
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

    /// Nil means the status isn't worth interrupting for. `working` and
    /// `idle` are transitions the user asked for, and `unset` says nothing.
    nonisolated static func body(for status: TaskStatus) -> String? {
        switch status {
        case .needsInput: "Waiting for your input."
        case .done: "Finished its turn."
        case .error: "The agent stopped unexpectedly."
        case .working, .idle, .unset: nil
        }
    }
}
