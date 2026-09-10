import Foundation

/// The dim second line of a subagent row: what it runs on, how long it has
/// been going, and how much of its context it has spent.
///
/// Every part is optional and the caption drops whatever it cannot state, so a
/// row that has only just appeared says less rather than something wrong.
///
/// The span comes from the transcript's own line timestamps rather than the
/// file's mtime, so a relaunch reports the same elapsed time it did before —
/// the rule `SubagentCompletionTracker` follows for its linger clock, for the
/// same reason.
nonisolated struct SubagentCaption: Equatable {
    var modelLabel: String?
    var elapsed: TimeInterval?
    /// Context spent, 0–1. Nil when the model implies no window.
    var contextFraction: Double?

    init(subagent: SubagentTranscript, now: Date = .now) {
        let transcript = subagent.transcript
        let model = (transcript.model ?? subagent.descriptor?.model).flatMap(AgentModel.recognizing)
        modelLabel = model?.label

        if let startedAt = transcript.startedAt {
            // A working agent's clock runs to now; a finished one stops at its
            // last line, so a row settles instead of counting up forever.
            let end = subagent.status == .working ? max(now, startedAt) : (transcript.lastActivityAt ?? startedAt)
            elapsed = end.timeIntervalSince(startedAt)
        }

        if let used = transcript.latestUsage?.contextUsedTokens,
           let window = model?.nominalContextWindow, window > 0 {
            contextFraction = min(Double(used) / Double(window), 1)
        }
    }

    var text: String {
        var parts: [String] = []
        if let modelLabel { parts.append(modelLabel) }
        if let elapsed { parts.append(Self.formatted(elapsed: elapsed)) }
        if let contextFraction {
            parts.append("\(Int((contextFraction * 100).rounded()))% context")
        }
        return parts.joined(separator: " · ")
    }

    static func formatted(elapsed: TimeInterval) -> String {
        ElapsedTime.formatted(elapsed)
    }
}
