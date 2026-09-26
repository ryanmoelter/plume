import Foundation

/// A live-agent removal awaiting confirmation.
struct PendingLiveAgentRemoval: Identifiable {
    let task: WorkTask
    let verb: WorktreeRemovalVerb

    var id: UUID { task.id }

    var dialogTitle: String {
        "\(verb.title) “\(task.title)”?"
    }

    var message: String {
        switch verb {
        case .archive: "This task has a live agent running. Archiving it now stops that agent."
        case .delete: "This task has a live agent running. Deleting it now stops that agent, and cannot be undone."
        }
    }
}

/// Whether a task has a tab running a live agent, so removing (archiving or
/// deleting) it needs confirmation first — otherwise the action silently
/// kills whatever that agent was doing.
///
/// Kept out of the views, and split from the session lookup below, so the
/// decision itself (`isLive`) is testable without a running session.
enum TaskRemovalSafety {
    static func hasLiveAgent(_ task: WorkTask) -> Bool {
        task.orderedTabs.contains { isLive(kind: $0.kind, hasExited: hasExited($0)) }
    }

    /// A plain terminal tab is never in scope: only an agent tab whose
    /// process hasn't exited counts as live.
    static func isLive(kind: TabKind, hasExited: Bool) -> Bool {
        kind == .agent && !hasExited
    }

    /// The headless transport's session lives in `AgentSessionManager`; the
    /// terminal transport's PTY lives in `SurfaceManager`. Neither having a
    /// session at all (never launched) reads as exited.
    private static func hasExited(_ tab: TaskTab) -> Bool {
        switch tab.transport {
        case .headless:
            return AgentSessionManager.shared.existingSession(for: tab.id)?.hasExited ?? true
        case .terminal:
            return SurfaceManager.shared.existingSession(for: tab.id)?.hasExited ?? true
        }
    }
}
