import Foundation

/// Recognizes command mode: a message starting with `!` runs as a shell
/// command rather than being said to the agent, the way the CLI's bash mode
/// does.
///
/// Pure, like `SlashCommandMatcher`, so the composer is not needed to test it.
/// Unlike a slash command there is no name to validate — a command line is
/// arbitrary text — so the `!` prefix alone is the signal.
enum CommandModeMatcher {
    /// A literal `!` is written `\!`, which sends as prose.
    private static let escapePrefix = "\\!"

    /// Whether `text` is being typed as a command: a leading `!`, whether or
    /// not anything follows it yet.
    ///
    /// Looser than `parse`, and deliberately so. Styling answers "are you in
    /// this mode", which is true the instant the `!` is typed — waiting for a
    /// first command character would leave that keystroke unacknowledged and
    /// read as the mode not having engaged.
    private static func isEnteringCommand(_ text: String) -> Bool {
        text.hasPrefix("!")
    }

    /// The whole message, for styling it monospaced. Nil when `text` is not
    /// being typed as a command.
    static func commandRange(text: String) -> NSRange? {
        guard isEnteringCommand(text) else { return nil }
        return NSRange(location: 0, length: (text as NSString).length)
    }

    /// Just the leading `!`, which styles red rather than monospace — running
    /// a command is destructive in a way saying something is not. Nil exactly
    /// when `commandRange` is, so the two never disagree.
    static func markerRange(text: String) -> NSRange? {
        guard isEnteringCommand(text) else { return nil }
        return NSRange(location: 0, length: 1)
    }

    /// The command to run — everything after the `!`, trimmed. Nil when
    /// `text` is not a command, or is only the `!` with nothing to run.
    ///
    /// Stricter than the styling range: a bare `!` looks like command mode
    /// while it is being typed but has nothing to execute, so it sends as
    /// ordinary text rather than running an empty command.
    static func parse(_ text: String) -> String? {
        guard isEnteringCommand(text) else { return nil }
        let command = String(text.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        return command.isEmpty ? nil : command
    }

    /// `text` as it should be sent when it is not a command, unescaping a
    /// leading `\!` to the literal `!` the user meant.
    static func unescaped(_ text: String) -> String {
        guard text.hasPrefix(escapePrefix) else { return text }
        return String(text.dropFirst())
    }
}
