import Foundation

/// The dim second line of a subagent row: what it runs on, what kind of
/// agent it is, and how much of its context it has spent. How long it has
/// been going is kept here too, but shown elsewhere on the row, beside the
/// chevron.
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
    var agentType: String?
    var elapsed: TimeInterval?
    var contextUsedTokens: Int?
    var contextWindow: Int?

    init(subagent: SubagentTranscript, now: Date = .now) {
        let transcript = subagent.transcript
        let model = (transcript.model ?? subagent.descriptor?.model).flatMap {
            AgentModel.recognizing($0, provider: subagent.provider)
        }
        modelLabel = model?.label
        agentType = subagent.descriptor?.agentType

        if let startedAt = transcript.startedAt {
            // A working agent's clock runs to now; a finished one stops at its
            // last line, so a row settles instead of counting up forever.
            let end = subagent.status == .working ? max(now, startedAt) : (transcript.lastActivityAt ?? startedAt)
            elapsed = end.timeIntervalSince(startedAt)
        }

        contextUsedTokens = transcript.latestUsage?.contextUsedTokens
        contextWindow = model?.nominalContextWindow
    }

    /// Model, agent type, then the raw context spent — "150k/200k" rather
    /// than a percentage, since a count says something on its own and a
    /// percentage needs the window to mean anything.
    var text: String {
        var parts: [String] = []
        if let modelLabel { parts.append(modelLabel) }
        if let agentType { parts.append(agentType) }
        if let contextUsedTokens, let contextWindow, contextWindow > 0 {
            parts.append("\(Self.formatted(tokens: contextUsedTokens))/\(Self.formatted(tokens: contextWindow))")
        }
        return parts.joined(separator: " · ")
    }

    var elapsedText: String? {
        elapsed.map(Self.formatted(elapsed:))
    }

    static func formatted(elapsed: TimeInterval) -> String {
        ElapsedTime.formatted(elapsed)
    }

    static func formatted(tokens count: Int) -> String {
        if count >= 1_000_000 {
            let value = Double(count) / 1_000_000
            return value.truncatingRemainder(dividingBy: 1) == 0
                ? "\(Int(value))M" : String(format: "%.1fM", value)
        }
        if count >= 1_000 { return "\(count / 1_000)k" }
        return "\(count)"
    }
}
