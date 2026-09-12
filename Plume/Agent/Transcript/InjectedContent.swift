import Foundation

/// What a `type: "user"` transcript line actually is.
///
/// Claude Code writes far more than typed messages as user lines: a skill's
/// whole body, a slash command and its output, a shell command run with `!`,
/// notifications, and interruptions all arrive with `role: "user"`. Rendering
/// them as prose puts words in the user's mouth, so the chat classifies each
/// line and renders injected ones as a compact marker instead.
nonisolated enum InjectedContent: Equatable {
    /// Genuinely typed by the user.
    case userMessage
    /// A skill's body, injected when the skill is invoked.
    case skill(name: String)
    /// A slash command the user ran, from its `<command-name>` block.
    case slashCommand(name: String, arguments: String? = nil)
    /// A slash command's output, named by the command that produced it when
    /// the preceding line identified one.
    case commandOutput(command: String? = nil)
    /// The boilerplate Claude Code prepends when a local command runs.
    case commandCaveat
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
    /// The summary a compaction wrote back as context. Thousands of words,
    /// and none of them the user's.
    case compactSummary

    /// Whether this should render as the user's own prose.
    var isUserProse: Bool { self == .userMessage }

    /// A short label for the marker row. Nil for a real message, which has no
    /// marker.
    var markerLabel: String? {
        switch self {
        case .userMessage: return nil
        case .skill(let name): return "Skill: \(name)"
        case .slashCommand(let name, let arguments):
            guard let arguments else { return name }
            return "\(name) \(arguments)"
        case .commandOutput(let command):
            guard let command else { return "Command output" }
            return "Output of \(command)"
        case .commandCaveat: return "Command caveat"
        case .shellCommand(let command): return command
        case .shellOutput: return "Shell output"
        case .taskNotification: return "Background task finished"
        case .interrupted: return "Interrupted"
        case .systemNote: return "System note"
        case .compactSummary: return "Compacted context"
        }
    }

    /// An SF Symbol for the marker row.
    var markerSymbol: String {
        switch self {
        case .userMessage: return "person"
        case .skill: return "wand.and.stars"
        case .slashCommand, .commandOutput: return "chevron.forward.square"
        case .commandCaveat: return "info.circle"
        case .shellCommand, .shellOutput: return "terminal"
        case .taskNotification: return StatusSymbol.terminalInput.name
        case .interrupted: return StatusSymbol.interruption.name
        case .systemNote: return "info.circle"
        case .compactSummary: return "arrow.down.right.and.arrow.up.left"
        }
    }

    /// How an expanded body reads.
    enum BodyStyle {
        case monospaced
        case markdown
    }

    /// A command's output is prose and tables — a `/context` dump is a
    /// markdown table — as is a compaction summary. The rest are literal
    /// wrapper blocks and command output that monospace serves better.
    var bodyStyle: BodyStyle {
        switch self {
        case .commandOutput, .commandCaveat, .compactSummary: return .markdown
        default: return .monospaced
        }
    }

    /// The text to show in the expanded body. A markdown body loses its
    /// wrapper tag, so the row renders the content rather than the
    /// transcript's XML.
    func bodyText(_ raw: String) -> String {
        bodyStyle == .markdown ? Self.unwrapped(raw) : raw
    }

    /// The contents of a string that is entirely one `<tag>…</tag>` element,
    /// or the string unchanged when it is anything else.
    private static func unwrapped(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("<"), !trimmed.hasPrefix("</"),
              let openEnd = trimmed.firstIndex(of: ">")
        else { return text }
        let name = trimmed[trimmed.index(after: trimmed.startIndex)..<openEnd].prefix { !$0.isWhitespace }
        let close = "</\(name)>"
        guard !name.isEmpty, trimmed.hasSuffix(close) else { return text }
        let bodyEnd = trimmed.index(trimmed.endIndex, offsetBy: -close.count)
        let openAfter = trimmed.index(after: openEnd)
        guard openAfter <= bodyEnd else { return text }
        return trimmed[openAfter..<bodyEnd].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Classifies one user line from its text and `isMeta` flag.
    ///
    /// `isMeta` alone is not enough: it catches a skill body and the caveat
    /// block, but a slash command's expansion and its stdout are both
    /// `isMeta: false` and have to be recognized by their wrapper tag. A
    /// compaction summary carries neither marker and is only knowable from
    /// its own flag, so that is checked first.
    static func classify(
        text: String,
        isMeta: Bool,
        isCompactSummary: Bool = false,
        precedingCommand: String? = nil
    ) -> InjectedContent {
        if isCompactSummary { return .compactSummary }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // `<command-name>` and `<command-message>` appear in either order,
        // so the name is searched for rather than expected at the front.
        if trimmed.hasPrefix("<command-name>") || trimmed.hasPrefix("<command-message>") {
            return .slashCommand(
                name: tagged(trimmed, "command-name") ?? "Slash command",
                arguments: tagged(trimmed, "command-args")
            )
        }
        if trimmed.hasPrefix("<bash-input>") {
            return .shellCommand(command: tagged(trimmed, "bash-input") ?? "Shell command")
        }
        if trimmed.hasPrefix("<local-command-caveat") {
            return .commandCaveat
        }
        if trimmed.hasPrefix("<local-command-stdout") {
            return .commandOutput(command: precedingCommand)
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
