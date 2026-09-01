import Foundation

/// A model this UI can switch a running session to.
///
/// `token` is the CLI argument `/model` accepts; matches `claude --help`'s
/// aliases (each resolves to the latest of that family). `displayNames`
/// lists the transcript/statusline strings a running session reports back
/// for this model, so `recognizing(_:)` can map the strip's current value
/// to a selection.
nonisolated enum AgentModel: String, CaseIterable, Identifiable {
    case fable
    case opus
    case sonnet

    var id: String { rawValue }

    var token: String { rawValue }

    var label: String {
        switch self {
        case .fable: return "Fable"
        case .opus: return "Opus"
        case .sonnet: return "Sonnet"
        }
    }

    private var displayNames: [String] {
        switch self {
        case .fable: return ["claude-fable-5", "fable", "Fable 5"]
        case .opus: return ["claude-opus-5", "opus", "Opus 5"]
        case .sonnet: return ["claude-sonnet-5", "sonnet", "Sonnet 5"]
        }
    }

    /// Maps a transcript- or statusline-reported model string back to an
    /// option, or nil for an unfamiliar value. A `[1m]` context suffix is
    /// ignored, since it names a variant of the same model.
    static func recognizing(_ reported: String) -> AgentModel? {
        let stripped = reported
            .replacingOccurrences(of: #"\[[^\]]*\]$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return AgentModel.allCases.first {
            $0.displayNames.contains { $0.caseInsensitiveCompare(stripped) == .orderedSame }
        }
    }
}

/// An effort level this UI can switch a running session to, per
/// `claude --help`.
nonisolated enum AgentEffort: String, CaseIterable, Identifiable {
    case low
    case medium
    case high
    case xhigh
    case max

    var id: String { rawValue }

    var token: String { rawValue }

    var label: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .xhigh: return "X-High"
        case .max: return "Max"
        }
    }

    /// Maps a transcript- or statusline-reported effort string back to an
    /// option, or nil when it doesn't match one of the five levels.
    static func recognizing(_ reported: String) -> AgentEffort? {
        AgentEffort(rawValue: reported)
    }
}

/// Builds the slash-command lines `ChatComposer`/`TerminalSession.submit`
/// sends to change a running session's model or effort — both take effect
/// for that session only.
///
/// `AgentModel`/`AgentEffort` tokens are fixed enum cases, so there's no
/// free-text path into the built command today. `sanitizedToken(_:)` is a
/// defense-in-depth check kept separate so a future free-text source (a
/// custom model name, say) can reuse it rather than trusting its input.
nonisolated enum ModelEffortCommand {
    enum InvalidTokenError: Error, Equatable {
        case containsWhitespaceOrNewline(String)
    }

    static func setModel(_ model: AgentModel) -> String {
        "/model \(model.token)"
    }

    static func setEffort(_ effort: AgentEffort) -> String {
        "/effort \(effort.token)"
    }

    /// Rejects a token containing whitespace or a newline, which could
    /// otherwise inject a second line into the terminal after the command.
    static func sanitizedToken(_ token: String) throws -> String {
        guard token.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            throw InvalidTokenError.containsWhitespaceOrNewline(token)
        }
        return token
    }
}
