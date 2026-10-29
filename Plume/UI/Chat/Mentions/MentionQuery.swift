import Foundation

/// The `@` or `#` token the caret sits in, if it should open the mention
/// menu. Command mode is the caller's check; everything that depends only on
/// the text is here.
nonisolated struct MentionQuery: Equatable, Sendable {
    enum Trigger: Character, Sendable {
        case at = "@"
        case hash = "#"
    }

    /// A prefix that keeps the menu to one source: `@linear:`, `@pr:`,
    /// `@file:`.
    enum Filter: String, CaseIterable, Sendable {
        case linear
        case pr
        case file

        init(source: MentionCandidate.Source) {
            switch source {
            case .linear: self = .linear
            case .pullRequests: self = .pr
            case .files: self = .file
            }
        }

        var source: MentionCandidate.Source {
            switch self {
            case .linear: .linear
            case .pr: .pullRequests
            case .file: .files
            }
        }

        var token: String { "@\(rawValue):" }

        var summary: String {
            switch self {
            case .linear: "Search Linear issues"
            case .pr: "Search pull requests"
            case .file: "Search files"
            }
        }
    }

    let trigger: Trigger
    /// What follows the trigger, any filter prefix and any opening quote, up
    /// to the caret.
    let text: String
    let filter: Filter?
    /// A path typed after a `"`, as `@"My Notes` is.
    let isQuoted: Bool
    /// UTF-16 offset of the trigger character.
    let triggerLocation: Int
    let caretLocation: Int

    init(
        trigger: Trigger,
        text: String,
        filter: Filter? = nil,
        isQuoted: Bool = false,
        triggerLocation: Int,
        caretLocation: Int
    ) {
        self.trigger = trigger
        self.text = text
        self.filter = filter
        self.isQuoted = isQuoted
        self.triggerLocation = triggerLocation
        self.caretLocation = caretLocation
    }

    /// The trigger through the caret.
    var range: NSRange {
        NSRange(location: triggerLocation, length: caretLocation - triggerLocation)
    }

    var sources: Set<MentionCandidate.Source> {
        if let filter { return [filter.source] }
        switch trigger {
        case .hash: return [.pullRequests]
        case .at: return isPathLike ? [.files] : [.linear, .pullRequests, .files]
        }
    }

    /// Nothing typed yet, so each source offers its defaults.
    var isBare: Bool { text.isEmpty && filter == nil && !isQuoted }

    var isPathLike: Bool {
        isQuoted || text.hasPrefix("~") || text.hasPrefix("/") || text.hasPrefix("./") || text.contains("/")
    }

    /// A `~/…` or `/…` query, whose file results are absolute paths.
    var isAbsolutePath: Bool {
        text.hasPrefix("~") || text.hasPrefix("/")
    }

    /// The controller closes a multi-word query that settles with no
    /// results, since by then the user is most likely writing prose.
    var containsSpace: Bool { text.contains(" ") }

    static let maximumWords = 5

    static let leadingBoundaries: Set<unichar> = Set("([\"'".utf16)
    private static let atSign = "@".utf16.first!
    private static let hashSign = "#".utf16.first!
    private static let quote = "\"".utf16.first!

    /// Judges code and links on the caret's line only, unless a fence before
    /// it may enclose that line.
    static func query(text: String, caretLocation: Int) -> MentionQuery? {
        query(text: text, caretLocation: caretLocation, markup: MentionMarkup.around(caretLocation, in: text))
    }

    static func query(text: String, caretLocation: Int, markup: MentionMarkup) -> MentionQuery? {
        let ns = text as NSString
        guard caretLocation > 0, caretLocation <= ns.length else { return nil }

        guard let triggerLocation = nearestTrigger(in: ns, before: caretLocation) else { return nil }
        let trigger: Trigger = ns.character(at: triggerLocation) == atSign ? .at : .hash

        let queryRange = NSRange(location: triggerLocation + 1, length: caretLocation - triggerLocation - 1)
        var query = ns.substring(with: queryRange)
        var filter: Filter?
        if trigger == .at, let prefixed = Filter.allCases.first(where: { query.lowercased().hasPrefix($0.rawValue + ":") }) {
            filter = prefixed
            query.removeFirst(prefixed.rawValue.count + 1)
        }
        var isQuoted = false
        if trigger == .at, query.hasPrefix("\"") {
            isQuoted = true
            query.removeFirst()
            if query.contains("\"") { return nil }
        }
        guard isOpen(query, trigger: trigger, isQuoted: isQuoted) else { return nil }

        // Spanning an existing link or code would reopen the menu on prose.
        let range = NSRange(location: triggerLocation, length: caretLocation - triggerLocation)
        if markup.excludes(range) { return nil }

        return MentionQuery(
            trigger: trigger,
            text: query,
            filter: filter,
            isQuoted: isQuoted,
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
            if character == atSign || character == hashSign, isBoundary(before: index, in: ns),
               !isInsideQuotedPath(index, caret: caret, in: ns) {
                return index
            }
            index -= 1
        }
        return nil
    }

    /// An `@` or `#` inside an open `@"…` path is part of the path.
    private static func isInsideQuotedPath(_ index: Int, caret: Int, in ns: NSString) -> Bool {
        var search = index - 1
        while search > 0 {
            let character = ns.character(at: search)
            if character == 0x0A || character == 0x0D || character == quote { break }
            search -= 1
        }
        guard search > 0, ns.character(at: search) == quote, ns.character(at: search - 1) == atSign else { return false }
        return isBoundary(before: search - 1, in: ns)
    }

    static func isBoundary(before index: Int, in ns: NSString) -> Bool {
        guard index > 0 else { return true }
        let previous = ns.character(at: index - 1)
        if let scalar = UnicodeScalar(previous), CharacterSet.whitespacesAndNewlines.contains(scalar) { return true }
        return leadingBoundaries.contains(previous)
    }

    private static func isOpen(_ query: String, trigger: Trigger, isQuoted: Bool) -> Bool {
        if query.hasPrefix(" ") { return false }
        if query.contains("  ") { return false }
        if trigger == .hash, query.hasPrefix("#") { return false }
        if query.unicodeScalars.contains(where: { $0 != " " && CharacterSet.whitespacesAndNewlines.contains($0) }) {
            return false
        }
        let words = query.split(separator: " ", omittingEmptySubsequences: true)
        if !isQuoted, words.count > 1 || query.hasSuffix(" "), let first = words.first,
           MentionReference.isCompleteToken(String(first), trigger: trigger) {
            return false
        }
        return words.count <= maximumWords
    }
}

/// Where code and links sit, which no mention reaches into.
nonisolated struct MentionMarkup: Equatable, Sendable {
    let codeRanges: [NSRange]
    let linkRanges: [NSRange]

    static let none = MentionMarkup(codeRanges: [], linkRanges: [])

    init(codeRanges: [NSRange], linkRanges: [NSRange]) {
        self.codeRanges = codeRanges
        self.linkRanges = linkRanges
    }

    init(spans: [MarkdownHighlighter.Span], offset: Int = 0) {
        var code: [NSRange] = []
        var links: [NSRange] = []
        for span in spans where span.range.length > 0 {
            let range = NSRange(location: span.range.location + offset, length: span.range.length)
            switch span.style {
            case .inlineCode, .codeBlock: code.append(range)
            case .link: links.append(range)
            default: break
            }
        }
        codeRanges = code
        linkRanges = links
    }

    static func whole(_ text: String) -> MentionMarkup {
        MentionMarkup(spans: MarkdownHighlighter.spans(in: text))
    }

    /// Inline code and links never cross a line, so the line holding
    /// `location` is enough unless a fence opened before it.
    static func around(_ location: Int, in text: String) -> MentionMarkup {
        let ns = text as NSString
        let line = ns.lineRange(for: NSRange(location: min(max(location, 0), ns.length), length: 0))
        if mayBeFenced(before: line.location, in: ns) { return whole(text) }
        return MentionMarkup(spans: MarkdownHighlighter.spans(in: ns.substring(with: line)), offset: line.location)
    }

    static func mayBeFenced(before location: Int, in ns: NSString) -> Bool {
        let before = NSRange(location: 0, length: location)
        return ns.range(of: "```", range: before).location != NSNotFound
            || ns.range(of: "~~~", range: before).location != NSNotFound
    }

    func excludes(_ range: NSRange) -> Bool {
        if ComposerCodeRanges.intersectsCode(range, codeRanges: codeRanges) { return true }
        return linkRanges.contains { NSIntersectionRange(range, $0).length > 0 }
    }
}
