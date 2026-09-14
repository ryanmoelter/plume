import Foundation

/// Pure filtering/ranking for slash-command autocomplete, kept free of
/// SwiftUI so it can be tested without a composer or a headless session.
enum SlashCommandMatcher {
    /// Matches for `query` against `commands`, ranked prefix-first, then
    /// alphabetically within each rank. `query` excludes the leading `/`.
    static func matches(query: String, in commands: [SlashCommand]) -> [SlashCommand] {
        guard !query.isEmpty else {
            return commands.sorted { $0.name < $1.name }
        }
        let needle = query.lowercased()
        let prefixMatches = commands
            .filter { $0.name.lowercased().hasPrefix(needle) }
            .sorted { $0.name < $1.name }
        let substringMatches = commands
            .filter { !$0.name.lowercased().hasPrefix(needle) && $0.name.lowercased().contains(needle) }
            .sorted { $0.name < $1.name }
        return prefixMatches + substringMatches
    }

    /// The result of accepting a slash command: the composer's new text, the
    /// range of the leading token that was replaced, and the caret offset
    /// (UTF-16) it should land at — the end of the inserted `/name `, ahead
    /// of any arguments the user goes on to type.
    struct AcceptedCommand: Equatable {
        let text: String
        let replacedRange: NSRange
        let replacement: String
        let caretLocation: Int
    }

    /// Replaces the leading `/token` in `text` with `/name `, leaving the
    /// rest of the message (if any) untouched so arguments can follow
    /// immediately.
    static func accepting(_ command: SlashCommand, in text: String) -> AcceptedCommand {
        let ns = text as NSString
        let tokenEnd = ns.rangeOfCharacter(from: .whitespacesAndNewlines).location
        let firstTokenLength = tokenEnd == NSNotFound ? ns.length : tokenEnd
        let replacedRange = NSRange(location: 0, length: firstTokenLength)
        let replacement = "/\(command.name) "
        let newText = ns.replacingCharacters(in: replacedRange, with: replacement)
        return AcceptedCommand(
            text: newText,
            replacedRange: replacedRange,
            replacement: replacement,
            caretLocation: replacement.utf16.count
        )
    }

    /// The range of a leading `/name` token in `text` when `name` exactly
    /// matches one of `commandNames`, for styling a recognized command as
    /// the user types it. Nil when the message doesn't start with `/`, or
    /// the leading token isn't a known command name.
    ///
    /// Unlike `query(text:caretLocation:)`, this doesn't depend on the
    /// caret — the composer restyles on every keystroke regardless of where
    /// the caret sits.
    static func recognizedCommandRange(text: String, commandNames: Set<String>) -> NSRange? {
        guard text.hasPrefix("/") else { return nil }
        let ns = text as NSString
        let tokenEnd = ns.rangeOfCharacter(from: .whitespacesAndNewlines).location
        let tokenLength = tokenEnd == NSNotFound ? ns.length : tokenEnd
        guard tokenLength > 1 else { return nil }
        let name = ns.substring(with: NSRange(location: 1, length: tokenLength - 1))
        guard commandNames.contains(name) else { return nil }
        return NSRange(location: 0, length: tokenLength)
    }

    /// The slash-command query if the caret sits inside the composer's first
    /// token and that token starts with `/`; nil otherwise, which means the
    /// autocomplete should not show.
    ///
    /// The first token is delimited by whitespace or a newline, so a command
    /// typed on a later line (after arguments or more text above it) doesn't
    /// trigger this — only the very start of the message can be a command.
    static func query(text: String, caretLocation: Int) -> String? {
        guard text.hasPrefix("/") else { return nil }
        let ns = text as NSString
        // caretLocation == 0 sits before the slash itself — no token yet.
        guard caretLocation >= 1, caretLocation <= ns.length else { return nil }
        let tokenEnd = ns.rangeOfCharacter(from: .whitespacesAndNewlines).location
        let firstTokenLength = tokenEnd == NSNotFound ? ns.length : tokenEnd
        guard caretLocation <= firstTokenLength else { return nil }
        return ns.substring(with: NSRange(location: 1, length: caretLocation - 1))
    }
}
