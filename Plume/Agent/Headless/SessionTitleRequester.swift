import Foundation

/// Decides when a headless conversation should be titled, and what text the
/// title is drawn from.
///
/// Claude Code auto-titles only the interactive TUI, so a headless tab never
/// gets an `ai-title` line unless Plume asks for one. Asking costs a model
/// call, so this is deliberately stingy: once when the conversation has
/// something to describe, and again when a plan names the work better than the
/// opening message did.
///
/// Pure state, no I/O — the caller supplies the world and sends the request.
struct SessionTitleRequester {
    private var hasRequestedInitialTitle = false
    private var lastTitledPlanPath: String?

    /// What the caller knows at the end of a turn.
    struct Context {
        var transport: AgentTransport
        /// The name the user gave the task, if any. A user-named task shows
        /// that name instead of the tab's title, so titling it would be
        /// inference nobody sees.
        var userTaskName: String?
        var isWorking: Bool
        /// The text to title from: the opening user message, or whatever the
        /// caller considers the conversation's subject.
        var openingMessage: String?
        var planFilePath: String?
        /// The plan's own heading, when a plan file has one yet.
        var planTitle: String?
        /// True when the transcript already carries an `ai-title` — a resumed
        /// conversation the TUI or an earlier run already named.
        var hasExistingTitle: Bool
    }

    /// The text to title from, or nil to leave the title alone.
    ///
    /// Mutating because a request that is handed out is also recorded; asking
    /// twice for the same turn would fire twice.
    mutating func descriptionForTitleRequest(_ context: Context) -> String? {
        guard context.transport == .headless, !context.isWorking else { return nil }

        let taskName = context.userTaskName?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard taskName?.isEmpty ?? true else { return nil }

        if let reason = trigger(context) {
            guard let description = description(for: reason, in: context) else { return nil }
            record(reason)
            return description
        }
        return nil
    }

    private enum Trigger {
        case initial
        case plan(path: String)
    }

    private func trigger(_ context: Context) -> Trigger? {
        // A plan names the work better than the opening message, so it wins
        // even on the first turn that produces one.
        if let path = context.planFilePath, path != lastTitledPlanPath, context.planTitle != nil {
            return .plan(path: path)
        }
        guard !hasRequestedInitialTitle else { return nil }
        // A conversation picked back up is already named; only a later
        // trigger should rename it.
        return context.hasExistingTitle ? nil : .initial
    }

    private func description(for trigger: Trigger, in context: Context) -> String? {
        let text: String? = switch trigger {
        case .plan: context.planTitle
        case .initial: context.openingMessage
        }
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        // An empty description is answered with a null title, so it is not
        // worth the round trip.
        guard let trimmed, !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private mutating func record(_ trigger: Trigger) {
        hasRequestedInitialTitle = true
        if case .plan(let path) = trigger { lastTitledPlanPath = path }
    }
}
