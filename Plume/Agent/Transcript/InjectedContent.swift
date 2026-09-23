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
    /// Text the user pasted, which Claude Code wraps before sending. Unlike
    /// every other wrapper here it holds the user's own words, so it reads as
    /// prose rather than a marker.
    case pastedContent
    /// A message another Claude session sent this one.
    case agentMessage(name: String?)
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
    var isUserProse: Bool {
        switch self {
        case .userMessage, .pastedContent: return true
        default: return false
        }
    }

    /// Whether this renders as a bubble in another agent's voice.
    var isAgentMessage: Bool {
        if case .agentMessage = self { return true }
        return false
    }

    /// Whether this is a `!` command or its output, which render together as
    /// one block rather than as a marker.
    var isShell: Bool {
        switch self {
        case .shellCommand, .shellOutput: return true
        default: return false
        }
    }

    /// A short label for the marker row. Nil for a real message, which has no
    /// marker.
    var markerLabel: String? {
        switch self {
        case .userMessage, .pastedContent: return nil
        case .agentMessage(let name): return "Message from \(name ?? "another agent")"
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
        case .userMessage, .pastedContent: return "person"
        case .agentMessage: return "bubble.left.and.bubble.right"
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
        case .commandOutput, .commandCaveat, .compactSummary, .pastedContent, .agentMessage:
            return .markdown
        default: return .monospaced
        }
    }

    /// The text to show in the expanded body. A markdown body loses its
    /// wrapper tag, so the row renders the content rather than the
    /// transcript's XML.
    func bodyText(_ raw: String) -> String {
        switch self {
        case .agentMessage:
            return Self.element(named: Self.agentMessageTag, in: raw)?.body ?? raw
        default:
            return bodyStyle == .markdown ? Self.unwrapped(raw) : raw
        }
    }

    /// The contents of a string that is entirely one `<tag>…</tag>` element,
    /// or the string unchanged when it is anything else.
    private static func unwrapped(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("<"), !trimmed.hasPrefix("</"),
              let openEnd = trimmed.firstIndex(of: ">")
        else { return text }
        let name = String(
            trimmed[trimmed.index(after: trimmed.startIndex)..<openEnd].prefix { !$0.isWhitespace }
        )
        guard !name.isEmpty,
              let closeStart = closeTagStart(of: name, endingAt: trimmed.endIndex, in: trimmed)
        else { return text }
        let openAfter = trimmed.index(after: openEnd)
        guard openAfter <= closeStart else { return text }
        return String(trimmed[openAfter..<closeStart]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Where the close tag for `name` begins, when the string ends with one.
    ///
    /// Claude Code's paste wrapper repeats the open tag's attributes in the
    /// close tag — `</pasted_content id="fc7b">` — so a plain `</name>`
    /// suffix test never matches. Anything between the name and the final
    /// `>` is accepted as long as the tag closes the string.
    private static func closeTagStart(
        of name: String,
        endingAt end: String.Index,
        in text: String
    ) -> String.Index? {
        guard text[..<end].hasSuffix(">") else { return nil }
        let open = "</\(name)"
        guard let range = text.range(of: open, options: .backwards, range: text.startIndex..<end)
        else { return nil }
        let afterName = text[range.upperBound..<text.index(before: end)]
        // A longer name that merely starts with this one closes a different
        // element.
        guard afterName.first.map({ $0.isWhitespace }) ?? true else { return nil }
        return range.lowerBound
    }

    /// The open tag's attribute text and body of the first `<name …>…</name>`
    /// element in the string, wherever it sits.
    private static func element(named name: String, in text: String) -> (attributes: String, body: String)? {
        guard let openStart = text.range(of: "<\(name)"),
              let openEnd = text[openStart.upperBound...].firstIndex(of: ">")
        else { return nil }
        let attributes = String(text[openStart.upperBound..<openEnd])
        guard attributes.isEmpty || attributes.first!.isWhitespace else { return nil }
        let bodyStart = text.index(after: openEnd)
        guard let close = text.range(of: "</\(name)>", range: bodyStart..<text.endIndex) else { return nil }
        let body = String(text[bodyStart..<close.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (attributes, body)
    }

    private static let agentMessageTag = "cross-session-message"

    /// The sending session's name, from the open tag's `from-name`.
    private static func attribute(_ name: String, in attributes: String) -> String? {
        guard let key = attributes.range(of: "\(name)=\"") else { return nil }
        guard let close = attributes[key.upperBound...].firstIndex(of: "\"") else { return nil }
        let value = String(attributes[key.upperBound..<close])
        return value.isEmpty ? nil : value
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
        if trimmed.hasPrefix("<pasted_content") {
            return .pastedContent
        }
        // Claude Code wraps the peer's message in boilerplate on both sides,
        // so the tag opens a line rather than the text. Requiring a line of
        // its own keeps prose that mentions the tag mid-sentence the user's.
        if trimmed.range(of: "\n<\(agentMessageTag)") != nil || trimmed.hasPrefix("<\(agentMessageTag)"),
           let element = element(named: agentMessageTag, in: trimmed) {
            return .agentMessage(name: attribute("from-name", in: element.attributes))
        }
        if trimmed.hasPrefix("<system-reminder") {
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
