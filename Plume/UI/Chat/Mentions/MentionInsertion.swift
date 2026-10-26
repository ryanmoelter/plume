import Foundation

/// The text an accepted mention leaves in the composer: a Markdown link in
/// place of the typed token.
nonisolated enum MentionInsertion {
    /// Replaces the trigger through the caret, plus the rest of the word the
    /// caret sits in, with the candidate's link and one space, and puts the
    /// caret after that space.
    static func accepting(
        _ candidate: MentionCandidate,
        query: MentionQuery,
        in text: String,
        homeDirectory: String
    ) -> SlashCommandMatcher.AcceptedCommand {
        let ns = text as NSString
        var end = query.caretLocation
        while end < ns.length, !isWhitespace(ns.character(at: end)) { end += 1 }

        let link = markdownLink(for: candidate, homeDirectory: homeDirectory)
        let followedBySpace = end < ns.length && ns.character(at: end) == space
        let replacement = followedBySpace ? link : link + " "
        let replaced = NSRange(location: query.triggerLocation, length: end - query.triggerLocation)
        let newText = ns.replacingCharacters(in: replaced, with: replacement)
        let caret = query.triggerLocation + (link as NSString).length + 1
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

    private static func isWhitespace(_ character: unichar) -> Bool {
        guard let scalar = UnicodeScalar(character) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }
}
