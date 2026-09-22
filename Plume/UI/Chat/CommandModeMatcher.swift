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

    /// The draft after a leading `!` turns the composer into command mode,
    /// with the `!` itself removed — the mode is shown by the composer's chip
    /// and monospaced text, so the marker has nothing left to say. Nil when
    /// `text` does not start one.
    ///
    /// Checked on every change rather than on the first keystroke alone, so a
    /// pasted command enters the mode the same way a typed one does.
    static func enteringCommandMode(_ text: String) -> String? {
        guard text.hasPrefix("!") else { return nil }
        return String(text.dropFirst())
    }

    /// The command to run in a composer already in command mode: the draft,
    /// trimmed. Nil when there is nothing to run, so an empty command mode
    /// sends nothing rather than running a blank line.
    static func parse(_ text: String) -> String? {
        let command = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return command.isEmpty ? nil : command
    }

    /// `text` as it should be sent when it is not a command, unescaping a
    /// leading `\!` to the literal `!` the user meant.
    static func unescaped(_ text: String) -> String {
        guard text.hasPrefix(escapePrefix) else { return text }
        return String(text.dropFirst())
    }
}
