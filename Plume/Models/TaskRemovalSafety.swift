import Foundation

/// A removal of a task whose agent is mid-turn, awaiting confirmation.
struct PendingLiveAgentRemoval: Identifiable {
    let task: WorkTask
    let verb: WorktreeRemovalVerb

    var id: UUID { task.id }

    var dialogTitle: String {
        verb.dialogTitle(for: task.title)
    }

    var message: String {
        switch verb {
        case .archive: "An agent in this task is mid-turn. Archiving it now stops that turn."
        case .delete: "An agent in this task is mid-turn. Deleting it now stops that turn, and cannot be undone."
        }
    }
}

/// Whether removing (archiving or deleting) a task needs confirmation because
/// one of its agents is mid-turn. An agent at rest has nothing in flight to
/// lose, so its task archives silently.
enum TaskRemovalSafety {
    struct AgentTabState: Equatable {
        let status: TaskStatus
        let hasExited: Bool
    }

    static func hasActiveAgent(_ task: WorkTask) -> Bool {
        let states = task.orderedTabs
            .filter { $0.kind == .agent }
            .map { AgentTabState(status: StatusEngine.shared.status(forTab: $0.id), hasExited: hasExited($0)) }
        return needsConfirmation(states)
    }

    /// An exited process has no turn left to stop, whatever its last status
    /// said: a terminal tab's status is only as fresh as its last hook, and
    /// subagent activity comes from a transcript that outlives the process.
    static func needsConfirmation(_ states: [AgentTabState]) -> Bool {
        states.contains { !$0.hasExited && isMidTurn($0.status) }
    }

    /// A tab blocked on the user counts: its turn resumes once answered.
    static func isMidTurn(_ status: TaskStatus) -> Bool {
        switch status {
        case .working, .waitingOnSubagents,
             .planApproval, .questionAsked, .permissionNeeded, .needsTerminalInput:
            true
        case .notStarted, .awaitingReply, .done, .interrupted, .error:
            false
        }
    }

    /// Having no session at all (never launched) reads as exited.
    private static func hasExited(_ tab: TaskTab) -> Bool {
        switch tab.transport {
        case .headless:
            AgentSessionManager.shared.existingSession(for: tab.id)?.hasExited ?? true
        case .terminal:
            SurfaceManager.shared.existingSession(for: tab.id)?.hasExited ?? true
        }
    }
}
