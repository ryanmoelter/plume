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
        case .archive: "An agent in this task is still working. Archiving it now stops that agent mid-turn."
        case .delete: "An agent in this task is still working. Deleting it now stops that agent mid-turn, and cannot be undone."
        }
    }
}

/// Whether removing (archiving or deleting) a task needs confirmation because
/// one of its agents is mid-turn. An agent at rest has nothing in flight to
/// lose, so its task archives silently.
enum TaskRemovalSafety {
    static func hasActiveAgent(_ task: WorkTask) -> Bool {
        let statuses = task.orderedTabs
            .filter { $0.kind == .agent }
            .map { StatusEngine.shared.status(forTab: $0.id) }
        return needsConfirmation(tabStatuses: statuses)
    }

    static func needsConfirmation(tabStatuses: [TaskStatus]) -> Bool {
        tabStatuses.contains(where: isMidTurn)
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
}
