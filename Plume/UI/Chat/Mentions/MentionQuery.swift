import Foundation

/// The `@` or `#` token the caret sits in, if it should open the mention
/// menu. Command mode is the caller's check; everything that depends only on
/// the text is here.
nonisolated struct MentionQuery: Equatable, Sendable {
    enum Trigger: Character, Sendable {
        case at = "@"
        case hash = "#"
    }

    enum Scope: Equatable, Sendable {
        case all
        case files
        case pullRequests
    }

    let trigger: Trigger
    /// What follows the trigger, up to the caret.
    let text: String
    /// UTF-16 offset of the trigger character.
    let triggerLocation: Int
    let caretLocation: Int

    /// The trigger through the caret.
    var range: NSRange {
        NSRange(location: triggerLocation, length: caretLocation - triggerLocation)
    }

    var scope: Scope {
        switch trigger {
        case .hash: return .pullRequests
        case .at: return isPathLike ? .files : .all
        }
    }

    var isPathLike: Bool {
        text.hasPrefix("~") || text.hasPrefix("/") || text.hasPrefix("./") || text.contains("/")
    }

    /// A `~/…` or `/…` query, whose file results are absolute paths.
    var isAbsolutePath: Bool {
        text.hasPrefix("~") || text.hasPrefix("/")
    }

    /// The controller closes a multi-word query that settles with no
    /// results, since by then the user is most likely writing prose.
    var containsSpace: Bool { text.contains(" ") }

    static let maximumWords = 5

    private static let leadingBoundaries: Set<unichar> = Set("([\"'".utf16)
    private static let atSign = "@".utf16.first!
    private static let hashSign = "#".utf16.first!

    static func query(text: String, caretLocation: Int, codeRanges: [NSRange]) -> MentionQuery? {
        let ns = text as NSString
        guard caretLocation > 0, caretLocation <= ns.length else { return nil }

        guard let triggerLocation = nearestTrigger(in: ns, before: caretLocation) else { return nil }
        let trigger: Trigger = ns.character(at: triggerLocation) == atSign ? .at : .hash

        let queryRange = NSRange(location: triggerLocation + 1, length: caretLocation - triggerLocation - 1)
        let query = ns.substring(with: queryRange)
        guard isOpen(query, trigger: trigger) else { return nil }

        let triggerRange = NSRange(location: triggerLocation, length: 1)
        if ComposerCodeRanges.intersectsCode(triggerRange, codeRanges: codeRanges) { return nil }
        if isInsideLink(triggerLocation, text: text) { return nil }

        return MentionQuery(
            trigger: trigger,
            text: query,
            triggerLocation: triggerLocation,
            caretLocation: caretLocation
        )
    }

    /// The closest trigger at a word boundary on the caret's line. Only the
    /// closest one counts: a farther trigger would mean a query spanning an
    /// earlier mention.
    private static func nearestTrigger(in ns: NSString, before caret: Int) -> Int? {
        var index = caret - 1
        while index >= 0 {
            let character = ns.character(at: index)
            if character == 0x0A || character == 0x0D { return nil }
            if character == atSign || character == hashSign, isBoundary(before: index, in: ns) {
                return index
            }
            index -= 1
        }
        return nil
    }

    private static func isBoundary(before index: Int, in ns: NSString) -> Bool {
        guard index > 0 else { return true }
        let previous = ns.character(at: index - 1)
        if let scalar = UnicodeScalar(previous), CharacterSet.whitespacesAndNewlines.contains(scalar) { return true }
        return leadingBoundaries.contains(previous)
    }

    private static func isOpen(_ query: String, trigger: Trigger) -> Bool {
        if query.hasPrefix(" ") { return false }
        if query.contains("  ") { return false }
        if trigger == .hash, query.hasPrefix("#") { return false }
        if query.unicodeScalars.contains(where: { $0 != " " && CharacterSet.whitespacesAndNewlines.contains($0) }) {
            return false
        }
        let words = query.split(separator: " ", omittingEmptySubsequences: true)
        return words.count <= maximumWords
    }

    private static func isInsideLink(_ location: Int, text: String) -> Bool {
        MarkdownHighlighter.spans(in: text).contains { span in
            span.style == .link && NSLocationInRange(location, span.range)
        }
    }
}
