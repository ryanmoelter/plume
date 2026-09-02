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
