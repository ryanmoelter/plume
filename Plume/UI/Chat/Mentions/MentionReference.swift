import Foundation

/// A plain reference in a draft: `@DROID-123`, `#123`, `@path/to/file`,
/// `@folder/` or `@"My Notes.md"`. It follows the same boundary rules as a
/// `MentionQuery`, so it never starts inside a word, inside code or inside an
/// existing link. Only the shape is checked here; whether the issue, pull
/// request or file exists is `MentionResolver`'s question.
nonisolated struct MentionReference: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        /// Uppercased.
        case linear(identifier: String)
        case pullRequest(number: Int)
        /// Relative to the tab directory, or absolute as typed (`~/…`,
        /// `/…`). A folder's path has no trailing `/`, except `/` itself.
        case file(path: String, isDirectory: Bool)
    }

    /// The whole token, trigger and any quotes included.
    let range: NSRange
    let kind: Kind

    static func references(in text: String) -> [MentionReference] {
        guard text.contains(where: { $0 == "@" || $0 == "#" }) else { return [] }
        return references(in: text, markup: .whole(text))
    }

    static func references(in text: String, markup: MentionMarkup) -> [MentionReference] {
        let ns = text as NSString
        var found: [MentionReference] = []
        var index = 0
        while index < ns.length {
            let character = ns.character(at: index)
            guard character == atSign || character == hashSign, MentionQuery.isBoundary(before: index, in: ns),
                  let reference = character == hashSign ? pullRequest(at: index, in: ns) : mention(at: index, in: ns)
            else {
                index += 1
                continue
            }
            if !markup.excludes(reference.range) { found.append(reference) }
            index = NSMaxRange(reference.range)
        }
        return found
    }

    /// What a reference to `kind` reads as in a draft.
    static func token(for kind: Kind) -> String {
        switch kind {
        case .linear(let identifier): "@" + identifier
        case .pullRequest(let number): "#\(number)"
        case .file(let path, let isDirectory): "@" + quotedIfNeeded(displayPath(path, isDirectory: isDirectory))
        }
    }

    /// A folder's path with its trailing `/`.
    static func displayPath(_ path: String, isDirectory: Bool) -> String {
        isDirectory && !path.hasSuffix("/") ? path + "/" : path
    }

    /// A path that would end early, or read as something other than a path,
    /// goes in quotes with `"` and `\` escaped.
    static func quotedIfNeeded(_ path: String) -> String {
        guard needsQuotes(path) else { return path }
        return "\"" + escapedForQuotes(path) + "\""
    }

    static func escapedForQuotes(_ path: String) -> String {
        var out = ""
        for character in path {
            if character == "\"" || character == "\\" { out.append("\\") }
            out.append(character)
        }
        return out
    }

    static func unescaped(_ quoted: String) -> String {
        var out = ""
        var escaping = false
        for character in quoted {
            if !escaping, character == "\\" {
                escaping = true
                continue
            }
            escaping = false
            out.append(character)
        }
        return out
    }

    static func needsQuotes(_ path: String) -> Bool {
        if path.isEmpty { return true }
        if path.contains(where: { $0.isWhitespace || quotedCharacters.contains($0) }) { return true }
        if path.hasSuffix(".") { return true }
        if let first = path.first, first == "@" || first == "#" { return true }
        return LinearIdentifierShape.isComplete(path)
    }

    /// A first word that already names something, after which the user is
    /// writing prose rather than a query.
    static func isCompleteToken(_ word: String, trigger: MentionQuery.Trigger) -> Bool {
        let token = trimmingClosers(word)
        switch trigger {
        case .hash:
            return PullRequestMentionSource.number(in: token) != nil
        case .at:
            return LinearIdentifierShape.isComplete(token) || token.contains("/") || token.contains(".")
        }
    }

    // MARK: - Scanning

    private static let atSign = "@".utf16.first!
    private static let hashSign = "#".utf16.first!
    private static let quote = "\"".utf16.first!
    private static let backslash = "\\".utf16.first!
    private static let period = ".".utf16.first!
    private static let closers = Set(")]},;:!?\"'".utf16)
    private static let quotedCharacters = Set("\"'()[]{}<>,;:!?`\\")

    private static func pullRequest(at index: Int, in ns: NSString) -> MentionReference? {
        var end = index + 1
        while end < ns.length, isASCIIDigit(ns.character(at: end)) { end += 1 }
        guard end > index + 1, endsToken(at: end, in: ns) else { return nil }
        let digits = ns.substring(with: NSRange(location: index + 1, length: end - index - 1))
        guard let number = Int(digits) else { return nil }
        return MentionReference(range: NSRange(location: index, length: end - index), kind: .pullRequest(number: number))
    }

    private static func mention(at index: Int, in ns: NSString) -> MentionReference? {
        let start = index + 1
        guard start < ns.length else { return nil }
        if ns.character(at: start) == quote { return quotedPath(at: index, in: ns) }

        var end = start
        while end < ns.length, !isWhitespace(ns.character(at: end)) { end += 1 }
        let word = ns.substring(with: NSRange(location: start, length: end - start)).lowercased()
        if MentionQuery.Filter.allCases.contains(where: { word.hasPrefix($0.rawValue + ":") }) { return nil }
        while end > start, closers.contains(ns.character(at: end - 1)) || ns.character(at: end - 1) == period {
            end -= 1
        }
        guard end > start else { return nil }
        let token = ns.substring(with: NSRange(location: start, length: end - start))
        guard let first = token.first, first != "@", first != "#", first != "\"" else { return nil }
        let range = NSRange(location: index, length: end - index)
        if LinearIdentifierShape.isComplete(token) {
            return MentionReference(range: range, kind: .linear(identifier: token.uppercased()))
        }
        return MentionReference(range: range, kind: file(token))
    }

    private static func quotedPath(at index: Int, in ns: NSString) -> MentionReference? {
        let contentStart = index + 2
        var cursor = contentStart
        while cursor < ns.length {
            let character = ns.character(at: cursor)
            if character == 0x0A || character == 0x0D { return nil }
            if character == quote { break }
            cursor += character == backslash ? 2 : 1
        }
        guard cursor < ns.length, cursor > contentStart else { return nil }
        let path = unescaped(ns.substring(with: NSRange(location: contentStart, length: cursor - contentStart)))
        let end = cursor + 1
        guard endsToken(at: end, in: ns) else { return nil }
        return MentionReference(range: NSRange(location: index, length: end - index), kind: file(path))
    }

    private static func file(_ typed: String) -> Kind {
        guard typed.hasSuffix("/") else { return .file(path: typed, isDirectory: false) }
        let path = typed.count > 1 ? String(typed.dropLast()) : typed
        return .file(path: path, isDirectory: true)
    }

    private static func endsToken(at index: Int, in ns: NSString) -> Bool {
        guard index < ns.length else { return true }
        let character = ns.character(at: index)
        return isWhitespace(character) || closers.contains(character) || character == period
    }

    private static func trimmingClosers(_ word: String) -> String {
        var token = Substring(word)
        while let last = token.last, last == "." || ")]},;:!?\"'".contains(last) { token = token.dropLast() }
        return String(token)
    }

    private static func isASCIIDigit(_ character: unichar) -> Bool {
        character >= 0x30 && character <= 0x39
    }

    private static func isWhitespace(_ character: unichar) -> Bool {
        guard let scalar = UnicodeScalar(character) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }
}
