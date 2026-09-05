import Foundation

/// Derives a subagent's live status from its own transcript tail, with the
/// parent's matching tool_result as the completion signal.
///
/// The tail carries most of the answer: a subagent that has stopped ends on
/// assistant prose (its report), while one still running ends mid-work on a
/// tool call or on the tool_result feeding one back. The parent's result is
/// what distinguishes a finished agent from one that merely paused, but only
/// for a *synchronous* spawn — an async spawn's result arrives the instant
/// the agent launches and says nothing about whether it finished.
nonisolated enum SubagentStatusDeriver {
    /// A spawn result that only reports the launch, which every async agent
    /// gets immediately. Matching it keeps a just-launched agent reading as
    /// working rather than done.
    private static let launchAcknowledgement = "Async agent launched successfully"

    static func derive(
        transcript: Transcript,
        parentResult: String?,
        parentResultIsError: Bool = false
    ) -> TaskStatus {
        guard let last = transcript.messages.last else { return .unset }

        if parentResultIsError { return .error }
        if last.blocks.contains(where: isErrorNotice) { return .error }
        if last.blocks.contains(where: isQuestion) { return .needsInput }

        let completed = parentResult.map { !$0.contains(launchAcknowledgement) } ?? false
        if completed { return .done }

        // Trailing prose from the agent is its report, so a spawn whose
        // result we never saw still reads as finished rather than stuck.
        if last.role == .assistant, last.blocks.contains(where: isProse) { return .done }
        return .working
    }

    /// The two tools that stop and wait for a person.
    private static func isQuestion(_ block: ChatBlock) -> Bool {
        guard case .toolCall(let call) = block else { return false }
        guard call.result == nil else { return false }
        return call.name == "AskUserQuestion" || call.name == "ExitPlanMode"
    }

    private static func isErrorNotice(_ block: ChatBlock) -> Bool {
        guard case .notice(let notice) = block else { return false }
        return notice.kind == .error
    }

    private static func isProse(_ block: ChatBlock) -> Bool {
        guard case .markdown(let text) = block else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
