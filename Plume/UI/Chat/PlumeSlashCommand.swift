import Foundation

/// A slash command Plume serves itself, rather than passing to the CLI.
///
/// `/rc` is one because the CLI's own `remote-control` command renders an
/// interactive TUI component and ships no non-interactive variant — it never
/// appears in the `initialize` reply's commands, and sending the text does
/// nothing. Plume drives the `remote_control` control request instead.
///
/// `/add-dir` is one because the folder list it changes is Plume's: the CLI
/// restores no added folder on a resume, so one added inside the session
/// would vanish at the next relaunch.
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
        ),
        SlashCommand(
            name: "btw",
            description: "Ask in a side chat, answered without disturbing this conversation",
            argumentHint: "<question>",
            isPlumeProvided: true
        ),
        SlashCommand(
            name: "add-dir",
            description: "Let this conversation reach another folder",
            argumentHint: "[path]",
            isPlumeProvided: true
        )
    ]

    enum Parsed: Equatable {
        case remoteControl(name: String?)
        case sideQuestion(question: String)
        /// An empty path asks for a folder picker.
        case addDirectory(path: String)
    }

    /// Recognizes a message that is *entirely* one of Plume's commands.
    ///
    /// Deliberately stricter than `SlashCommandMatcher`, which matches a
    /// leading token with prose after it. Anything longer than a command and
    /// one argument is an ordinary message, so it falls through and is sent
    /// rather than silently swallowed. `/btw` and `/add-dir` are the
    /// exceptions: a question or a path is not a single token, so everything
    /// after the command name is the argument.
    static func parse(_ text: String) -> Parsed? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let tokens = trimmed.split(whereSeparator: \.isWhitespace)
        guard let first = tokens.first else { return nil }
        if first == "/btw" {
            let question = trimmed
                .dropFirst(first.count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !question.isEmpty else { return nil }
            return .sideQuestion(question: question)
        }
        if first == "/add-dir" {
            let path = trimmed
                .dropFirst(first.count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.contains(where: \.isNewline) else { return nil }
            return .addDirectory(path: unquoted(path))
        }
        guard (1...2).contains(tokens.count), first == "/rc" else { return nil }
        return .remoteControl(name: tokens.count == 2 ? String(tokens[1]) : nil)
    }

    /// A path pasted from Terminal often arrives quoted, or with its spaces
    /// backslash-escaped.
    private static func unquoted(_ path: String) -> String {
        for quote in ["\"", "'"] where path.count >= 2 && path.hasPrefix(quote) && path.hasSuffix(quote) {
            return String(path.dropFirst().dropLast())
        }
        return path.replacingOccurrences(of: "\\ ", with: " ")
    }
}
