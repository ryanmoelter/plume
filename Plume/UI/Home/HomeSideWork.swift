import Foundation

/// One piece of work a tab runs beside its main turn: a subagent, or a
/// background task such as a `Monitor`, a backgrounded `Bash` or a `Workflow`.
struct HomeSideWork: Identifiable, Equatable {
    enum Kind: Equatable {
        case subagent
        case backgroundTask(BackgroundTaskTracker.Kind)
    }

    let id: String
    let kind: Kind
    /// The chip's label: the subagent's type, or the background task's kind.
    let typeName: String
    let status: TaskStatus
    /// What the work was asked to do, for the chip's tooltip.
    let detail: String?

    /// The tab's unsettled subagents, in the order their store lists them,
    /// then its background tasks, oldest first. A finished subagent stays
    /// until its linger elapses, so its glyph can be seen to land.
    static func items(
        subagents: [SubagentTranscript],
        hasSettled: (SubagentTranscript) -> Bool,
        backgroundTasks: [BackgroundTaskTracker.Entry]
    ) -> [HomeSideWork] {
        let subagentItems = subagents.filter { !hasSettled($0) }.map { subagent in
            HomeSideWork(
                id: "subagent-\(subagent.id)",
                kind: .subagent,
                typeName: subagent.descriptor?.agentType ?? "Agent",
                status: subagent.status,
                detail: subagent.descriptor?.description
            )
        }
        let backgroundItems = backgroundTasks.map { entry in
            HomeSideWork(
                id: "background-\(entry.id)",
                kind: .backgroundTask(entry.kind),
                typeName: entry.kind.label,
                status: .working,
                detail: entry.description
            )
        }
        return subagentItems + backgroundItems
    }
}
