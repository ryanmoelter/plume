import Foundation

/// A slash command Plume serves itself, rather than passing to the CLI.
///
/// `/rc` is one because the CLI's own `remote-control` command renders an
/// interactive TUI component and ships no non-interactive variant — it never
/// appears in the `initialize` reply's commands, and sending the text does
/// nothing. Plume drives the `remote_control` control request instead.
///
/// Kept out of `HeadlessSession.slashCommands`, which stays exactly what the
/// CLI reported.
enum PlumeSlashCommand {
    static let all: [SlashCommand] = [
        SlashCommand(
            name: "rc",
            description: "Control this session from your phone or claude.ai/code",
            argumentHint: "[name]",
            isPlumeProvided: true
        )
    ]

    enum Parsed: Equatable {
        case remoteControl(name: String?)
    }

    /// Recognizes a message that is *entirely* one of Plume's commands.
    ///
    /// Deliberately stricter than `SlashCommandMatcher`, which matches a
    /// leading token with prose after it. Anything longer than a command and
    /// one argument is an ordinary message, so it falls through and is sent
    /// rather than silently swallowed.
    static func parse(_ text: String) -> Parsed? {
        let tokens = text.split(whereSeparator: \.isWhitespace)
        guard (1...2).contains(tokens.count), tokens[0] == "/rc" else { return nil }
        return .remoteControl(name: tokens.count == 2 ? String(tokens[1]) : nil)
    }
}
