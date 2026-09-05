import Foundation

/// What the parent transcript records about a spawned subagent's outcome.
///
/// The parent is the only place a subagent's completion is stated rather than
/// inferred, and it states it two ways: the spawning call's `toolUseResult`,
/// and — for a background agent the parent never blocked on — a `task_status`
/// attachment. Both carry an explicit status, so neither needs the result
/// text read as English.
nonisolated enum SubagentParentSignal: Equatable {
    /// The parent holds a real report of what the agent did.
    case completed
    /// The agent was launched asynchronously and this says only that it
    /// started.
    case launched
    /// The spawn itself failed.
    case failed
}

/// Derives a subagent's live status from its own transcript and whatever the
/// parent recorded about it.
///
/// Two signals mean done, and both are unambiguous:
///
/// - The last assistant turn to carry a `stop_reason` reports `end_turn`, so
///   the model finished speaking rather than stopping to call a tool.
/// - The parent holds a real completion for the agent — a `toolUseResult` with
///   `status: "completed"`, or a `task_status` attachment saying the same.
///
/// A transcript whose last message is the user's interruption reads as
/// `interrupted` instead. Everything softer reads as working. Trailing prose
/// is *not* a signal,
/// though it looks like one: a subagent narrates between tool calls, so its
/// file very often ends on an assistant paragraph while the agent is still
/// mid-task — 49 of 210 transcripts in a sampled corpus, every one of which
/// would have shown a false green check.
///
/// The parent's completion has to be read as a status rather than as text
/// because 88% of spawns are asynchronous and answered immediately with a
/// launch acknowledgement, which says nothing about the outcome.
nonisolated enum SubagentStatusDeriver {
    static func derive(
        transcript: Transcript,
        parentSignal: SubagentParentSignal?,
        parentResultIsError: Bool = false
    ) -> TaskStatus {
        guard let last = transcript.messages.last else { return .unset }

        if parentResultIsError || parentSignal == .failed { return .error }
        if last.blocks.contains(where: isErrorNotice) { return .error }
        if last.blocks.contains(where: isQuestion) { return .needsInput }

        if isFinished(transcript: transcript, parentSignal: parentSignal) { return .done }
        if last.blocks.contains(where: isInterruption) { return .interrupted }
        return .working
    }

    /// A parent completion outranks the sidecar, because the sidecar's tail is
    /// unreliable in exactly the case that matters: the agent's closing message
    /// is written while streaming and carries `stop_reason: null`, so the last
    /// value the parser keeps is the `tool_use` from an earlier turn and the
    /// agent reads as working forever. 20 of 510 sampled agents ended that way
    /// with a real report already sitting in the parent.
    ///
    /// Absent that, a turn ending on `tool_use` is mid-step, which keeps a
    /// resumed agent from staying stuck on an `end_turn` it has worked past.
    private static func isFinished(transcript: Transcript, parentSignal: SubagentParentSignal?) -> Bool {
        if parentSignal == .completed { return true }
        return transcript.lastStopReason == "end_turn"
    }

    /// The user pressing escape ends the agent where it stood, so its file
    /// keeps the `tool_use` stop reason of the step it was on and it would
    /// otherwise read as working forever — 4 of 215 transcripts in the
    /// sampled corpus, every one still spinning.
    ///
    /// Only the *last* message counts. An interrupted agent that was told to
    /// carry on has the marker mid-file and goes on to finish normally, which
    /// is the fifth of those five. And this is checked last, so it can only
    /// ever replace `working`: a parent completion or an `end_turn` still
    /// means done, rather than this guessing over a signal that outranks it.
    private static func isInterruption(_ block: ChatBlock) -> Bool {
        guard case .injected(let content, _) = block else { return false }
        return content == .interrupted
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
