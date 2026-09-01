import Foundation

/// What a `type: "user"` transcript line actually is.
///
/// Claude Code writes far more than typed messages as user lines: a skill's
/// whole body, a slash command and its output, a shell command run with `!`,
/// notifications, and interruptions all arrive with `role: "user"`. Rendering
/// them as prose puts words in the user's mouth, so the chat classifies each
/// line and renders injected ones as a compact marker instead.
enum InjectedContent: Equatable {
    /// Genuinely typed by the user.
    case userMessage
    /// A skill's body, injected when the skill is invoked.
    case skill(name: String)
    /// A slash command the user ran, from its `<command-name>` block.
    case slashCommand(name: String)
    /// A slash command's output.
    case commandOutput
    /// A shell command run from the composer with `!`.
    case shellCommand(command: String)
    /// That shell command's output.
    case shellOutput
    /// A background task reporting back.
    case taskNotification
    /// The user pressed escape mid-turn.
    case interrupted
    /// Guidance the harness injected, not something the user wrote.
    case systemNote

    /// Whether this should render as the user's own prose.
    var isUserProse: Bool { self == .userMessage }

    /// A short label for the marker row. Nil for a real message, which has no
    /// marker.
    var markerLabel: String? {
        switch self {
        case .userMessage: return nil
        case .skill(let name): return "Skill: \(name)"
        case .slashCommand(let name): return name
        case .commandOutput: return "Command output"
        case .shellCommand(let command): return command
        case .shellOutput: return "Shell output"
        case .taskNotification: return "Background task finished"
        case .interrupted: return "Interrupted"
        case .systemNote: return "System note"
        }
    }

    /// An SF Symbol for the marker row.
    var markerSymbol: String {
        switch self {
        case .userMessage: return "person"
        case .skill: return "wand.and.stars"
        case .slashCommand, .commandOutput: return "chevron.forward.square"
        case .shellCommand, .shellOutput: return "terminal"
        case .taskNotification: return "bell"
        case .interrupted: return "hand.raised"
        case .systemNote: return "info.circle"
        }
    }

    /// Classifies one user line from its text and `isMeta` flag.
    ///
    /// `isMeta` alone is not enough: it catches a skill body and the caveat
    /// block, but a slash command's expansion and its stdout are both
    /// `isMeta: false` and have to be recognized by their wrapper tag.
    static func classify(text: String, isMeta: Bool) -> InjectedContent {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // `<command-name>` and `<command-message>` appear in either order,
        // so the name is searched for rather than expected at the front.
        if trimmed.hasPrefix("<command-name>") || trimmed.hasPrefix("<command-message>") {
            return .slashCommand(name: tagged(trimmed, "command-name") ?? "Slash command")
        }
        if trimmed.hasPrefix("<bash-input>") {
            return .shellCommand(command: tagged(trimmed, "bash-input") ?? "Shell command")
        }
        if trimmed.hasPrefix("<local-command-stdout") || trimmed.hasPrefix("<local-command-caveat") {
            return .commandOutput
        }
        if trimmed.hasPrefix("<bash-stdout") || trimmed.hasPrefix("<bash-stderr") {
            return .shellOutput
        }
        if trimmed.hasPrefix("<task-notification") {
            return .taskNotification
        }
        if trimmed.hasPrefix("<system-reminder") || trimmed.hasPrefix("<cross-session-message") {
            return .systemNote
        }
        if trimmed.hasPrefix("[Request interrupted") {
            return .interrupted
        }
        if let name = skillName(trimmed) {
            return .skill(name: name)
        }
        // A meta line that matched nothing above is still not the user's
        // prose — better an unlabeled marker than words they never wrote.
        return isMeta ? .systemNote : .userMessage
    }

    /// The text inside the first `<tag>…</tag>` in the string.
    private static func tagged(_ text: String, _ tag: String) -> String? {
        guard let open = text.range(of: "<\(tag)>"),
              let close = text.range(of: "</\(tag)>", range: open.upperBound..<text.endIndex)
        else { return nil }
        let cleaned = text[open.upperBound..<close.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// A skill body opens with its own base directory, whose last path
    /// component is the skill's name.
    private static let skillPrefix = "Base directory for this skill:"

    private static func skillName(_ text: String) -> String? {
        guard text.hasPrefix(skillPrefix) else { return nil }
        let rest = text.dropFirst(skillPrefix.count)
        guard let line = rest.split(separator: "\n", maxSplits: 1).first else { return nil }
        let path = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? nil : name
    }
}
