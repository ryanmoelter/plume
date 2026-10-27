import Foundation

/// The text an accepted mention leaves in the composer: a plain reference
/// (`@DROID-123`, `#123`, `@path`) in place of the typed token. Sending
/// expands it into a Markdown link (`MentionExpansion`), whose helpers live
/// here too.
nonisolated enum MentionInsertion {
    /// Replaces the trigger through the caret, plus the rest of the word the
    /// caret sits in, with the candidate's reference, and puts the caret
    /// after it. Punctuation closing the word, and a sentence's final `.`,
    /// stay. A space follows the reference unless the text already goes on
    /// with one or with that punctuation, or the candidate drills in.
    static func accepting(
        _ candidate: MentionCandidate,
        query: MentionQuery,
        in text: String
    ) -> SlashCommandMatcher.AcceptedCommand {
        let ns = text as NSString
        var end = query.caretLocation
        while end < ns.length, !isWhitespace(ns.character(at: end)), !closesWord(ns.character(at: end)) { end += 1 }
        while end > query.caretLocation, ns.character(at: end - 1) == period { end -= 1 }

        let inserted = insertedText(for: candidate)
        let replaced = NSRange(location: query.triggerLocation, length: end - query.triggerLocation)
        let caretAfterInsertion = query.triggerLocation + (inserted as NSString).length
        if candidate.drillsIn {
            return .init(text: ns.replacingCharacters(in: replaced, with: inserted), caretLocation: caretAfterInsertion)
        }

        let next = end < ns.length ? ns.character(at: end) : nil
        let followedBySpace = next == space
        let followedByPunctuation = next.map { closesWord($0) || $0 == period } ?? false
        let replacement = followedBySpace || followedByPunctuation ? inserted : inserted + " "
        let newText = ns.replacingCharacters(in: replaced, with: replacement)
        return .init(text: newText, caretLocation: caretAfterInsertion + (followedByPunctuation ? 0 : 1))
    }

    /// A folder leaves its quote open, if it has one, so the path can go on.
    static func insertedText(for candidate: MentionCandidate) -> String {
        switch candidate {
        case .linear(let issue): return MentionReference.token(for: .linear(identifier: issue.identifier))
        case .pullRequest(let pull): return MentionReference.token(for: .pullRequest(number: pull.number))
        case .filter(let filter): return filter.token
        case .file(let entry):
            let path = MentionReference.displayPath(entry.path, isDirectory: entry.isDirectory)
            guard entry.isDirectory, MentionReference.needsQuotes(path) else {
                return "@" + MentionReference.quotedIfNeeded(path)
            }
            return "@\"" + MentionReference.escapedForQuotes(path)
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
