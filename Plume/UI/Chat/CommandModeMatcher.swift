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

    /// Whether `text` is a command, i.e. starts with `!` and has something
    /// other than whitespace after it.
    private static func isCommand(_ text: String) -> Bool {
        guard text.hasPrefix("!") else { return false }
        return !text.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The whole message, for styling it monospaced. Nil when `text` is not a
    /// command.
    static func commandRange(text: String) -> NSRange? {
        guard isCommand(text) else { return nil }
        return NSRange(location: 0, length: (text as NSString).length)
    }

    /// Just the leading `!`, which styles red rather than monospace — running
    /// a command is destructive in a way saying something is not. Nil exactly
    /// when `commandRange` is, so the two never disagree.
    static func markerRange(text: String) -> NSRange? {
        guard isCommand(text) else { return nil }
        return NSRange(location: 0, length: 1)
    }

    /// The command to run — everything after the `!`, trimmed. Nil when
    /// `text` is not a command.
    static func parse(_ text: String) -> String? {
        guard isCommand(text) else { return nil }
        return String(text.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `text` as it should be sent when it is not a command, unescaping a
    /// leading `\!` to the literal `!` the user meant.
    static func unescaped(_ text: String) -> String {
        guard text.hasPrefix(escapePrefix) else { return text }
        return String(text.dropFirst())
    }
}
