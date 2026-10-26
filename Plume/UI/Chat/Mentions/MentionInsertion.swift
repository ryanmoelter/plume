import Foundation

/// The text an accepted mention leaves in the composer: a Markdown link in
/// place of the typed token.
nonisolated enum MentionInsertion {
    /// Replaces the trigger through the caret, plus the rest of the word the
    /// caret sits in, with the candidate's link, and puts the caret after it.
    /// Punctuation closing the word, and a sentence's final `.`, stay. A
    /// space follows the link unless the text already goes on with one or
    /// with that punctuation.
    static func accepting(
        _ candidate: MentionCandidate,
        query: MentionQuery,
        in text: String,
        homeDirectory: String
    ) -> SlashCommandMatcher.AcceptedCommand {
        let ns = text as NSString
        var end = query.caretLocation
        while end < ns.length, !isWhitespace(ns.character(at: end)), !closesWord(ns.character(at: end)) { end += 1 }
        while end > query.caretLocation, ns.character(at: end - 1) == period { end -= 1 }

        let link = markdownLink(for: candidate, homeDirectory: homeDirectory)
        let next = end < ns.length ? ns.character(at: end) : nil
        let followedBySpace = next == space
        let followedByPunctuation = next.map { closesWord($0) || $0 == period } ?? false
        let replacement = followedBySpace || followedByPunctuation ? link : link + " "
        let replaced = NSRange(location: query.triggerLocation, length: end - query.triggerLocation)
        let newText = ns.replacingCharacters(in: replaced, with: replacement)
        let caret = query.triggerLocation + (link as NSString).length + (followedByPunctuation ? 0 : 1)
        return SlashCommandMatcher.AcceptedCommand(text: newText, caretLocation: caret)
    }

    static func markdownLink(for candidate: MentionCandidate, homeDirectory: String) -> String {
        switch candidate {
        case .linear(let issue):
            return link(label: issue.identifier, target: issue.url)
        case .pullRequest(let pull):
            return link(label: "#\(pull.number)", target: pull.url)
        case .file(let entry):
            let label = entry.isDirectory ? entry.name + "/" : entry.name
            return link(label: label, target: expandingTilde(entry.path, homeDirectory: homeDirectory))
        }
    }

    static func link(label: String, target: String) -> String {
        "[\(escapedLabel(label))](\(formattedTarget(target)))"
    }

    static func escapedLabel(_ label: String) -> String {
        var out = ""
        for character in label {
            if character == "\\" || character == "[" || character == "]" { out.append("\\") }
            out.append(character)
        }
        return out
    }

    /// A target with a space or parenthesis can't stand bare, so it goes in
    /// `<…>`, where only the angle brackets themselves need escaping.
    static func formattedTarget(_ target: String) -> String {
        guard target.contains(where: { $0.isWhitespace || "()<>".contains($0) }) else { return target }
        var out = "<"
        for character in target {
            if character == "<" || character == ">" { out.append("\\") }
            out.append(character)
        }
        return out + ">"
    }

    static func expandingTilde(_ path: String, homeDirectory: String) -> String {
        if path == "~" { return homeDirectory }
        guard path.hasPrefix("~/") else { return path }
        let home = homeDirectory.hasSuffix("/") ? String(homeDirectory.dropLast()) : homeDirectory
        return home + path.dropFirst()
    }

    private static let space = " ".utf16.first!
    private static let period = ".".utf16.first!
    private static let wordClosers = Set(")]},;:!?\"'".utf16)

    private static func closesWord(_ character: unichar) -> Bool { wordClosers.contains(character) }

    private static func isWhitespace(_ character: unichar) -> Bool {
        guard let scalar = UnicodeScalar(character) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }
}
