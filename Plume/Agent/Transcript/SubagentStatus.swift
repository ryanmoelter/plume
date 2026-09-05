import Foundation

/// Derives a subagent's live status from its own transcript.
///
/// Completion has one unambiguous signal: the last assistant turn to carry a
/// `stop_reason` reports `end_turn`, meaning the model finished speaking
/// rather than stopping to call a tool. Everything softer reads as working.
///
/// Trailing prose is *not* that signal, though it looks like one. A subagent
/// narrates between tool calls, so its file very often ends on an assistant
/// paragraph while the agent is still mid-task — 49 of 210 transcripts in a
/// sampled corpus, every one of which would have shown a false green check.
///
/// The parent's `tool_result` is not the signal either, because 88% of spawns
/// are asynchronous: their result arrives the instant the agent launches and
/// says nothing about whether it finished. Only a synchronous spawn's result
/// is a real report, and that arrives with the agent already at `end_turn`.
nonisolated enum SubagentStatusDeriver {
    /// The spawn result every async agent gets immediately, which reports the
    /// launch and nothing about the outcome.
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

        return isFinished(transcript: transcript, parentResult: parentResult) ? .done : .working
    }

    /// A turn that ended on `tool_use` is mid-step no matter what the parent
    /// reported, which keeps a resumed agent from staying stuck on the
    /// `end_turn` it has already worked past.
    private static func isFinished(transcript: Transcript, parentResult: String?) -> Bool {
        switch transcript.lastStopReason {
        case "end_turn": return true
        case .some: return false
        case nil: break
        }
        // No turn has closed yet, so only a synchronous spawn's real report
        // can say the agent is done.
        guard let parentResult else { return false }
        return !parentResult.contains(launchAcknowledgement)
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
}
