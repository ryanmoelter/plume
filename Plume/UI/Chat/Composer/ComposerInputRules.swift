import Foundation

/// Markdown shortcuts that convert as the user types, Typora/Notion style:
/// `- ` becomes a bullet, `**bold**` becomes bold, and so on.
///
/// Pure text in, `Edit` out — no `NSTextView`, no mutation. A caller feeds
/// one paragraph's plain text plus the character(s) just inserted; `edit(for:)`
/// says what to delete and what block kind or inline style to apply, or
/// returns nil when nothing should convert. Applying the edit is the
/// integration layer's job.
nonisolated enum ComposerInputRules {
    /// One paragraph's state at the moment `inserted` was just typed into it.
    struct Context {
        /// The paragraph's full plain text, already including `inserted`.
        let paragraphText: String
        /// The paragraph's block kind before this edit.
        let kind: ComposerBlockKind
        /// `inserted`'s UTF-16 offset within `paragraphText`, after insertion.
        let caret: Int
        /// The text just inserted — usually one character, but a multi-character
        /// paste or IME commit counts too.
        let inserted: String
        /// The previous paragraph's kind, for list-depth inheritance. Nil at
        /// the start of the document.
        let previousKind: ComposerBlockKind?
        /// UTF-16 ranges, relative to `paragraphText`, already carrying
        /// `.code` inline style — an emphasis delimiter touching one of these
        /// never converts.
        let codeRanges: [NSRange]

        init(
            paragraphText: String,
            kind: ComposerBlockKind,
            caret: Int,
            inserted: String,
            previousKind: ComposerBlockKind? = nil,
            codeRanges: [NSRange] = []
        ) {
            self.paragraphText = paragraphText
            self.kind = kind
            self.caret = caret
            self.inserted = inserted
            self.previousKind = previousKind
            self.codeRanges = codeRanges
        }
    }

    enum Edit: Equatable {
        /// Delete `markerRange` (paragraph-relative UTF-16) and set the paragraph's kind.
        case convertBlock(markerRange: NSRange, kind: ComposerBlockKind)
        /// Delete the two delimiter ranges and apply `style` to the content between them.
        case convertInline(openRange: NSRange, closeRange: NSRange, style: ComposerInlineStyle)
        /// Delete the whole `[text](url)` range and insert `text` carrying the link.
        case convertLink(range: NSRange, text: String, url: URL)
    }

    static func edit(for context: Context) -> Edit? {
        switch context.kind.kind {
        case .codeBlock, .verbatim:
            return nil
        case .paragraph:
            if let block = blockEdit(for: context) { return block }
        default:
            break
        }
        return inlineEdit(for: context)
    }

    // MARK: - Block rules

    /// Only reached when `context.kind` is `.paragraph` — a heading, list
    /// marker, or fence typed inside an existing heading/quote/list stays
    /// literal, matching Typora/Notion's "already-structured line" behavior.
    /// Every marker is anchored at paragraph start, so leading whitespace
    /// (including inside an existing list item) never matches.
    private static func blockEdit(for context: Context) -> Edit? {
        let ns = context.paragraphText as NSString

        if let level = headingLevel(ns), context.caret == level + 1 {
            return .convertBlock(markerRange: NSRange(location: 0, length: level + 1), kind: .heading(level))
        }
        if isBulletMarker(ns), context.caret == 2 {
            return .convertBlock(
                markerRange: NSRange(location: 0, length: 2),
                kind: .bullet(depth: inheritedListDepth(context.previousKind))
            )
        }
        if let (length, number) = numberedMarker(ns), context.caret == length {
            return .convertBlock(
                markerRange: NSRange(location: 0, length: length),
                kind: .numbered(depth: inheritedListDepth(context.previousKind), number: number)
            )
        }
        if isQuoteMarker(ns), context.caret == 2 {
            return .convertBlock(markerRange: NSRange(location: 0, length: 2), kind: .quote)
        }
        return codeFenceEdit(for: context, ns: ns)
    }

    /// `#` through `######` followed by a space; a seventh `#` never matches,
    /// so `####### ` stays literal.
    private static func headingLevel(_ ns: NSString) -> Int? {
        var level = 0
        while level < ns.length, level < 7, ns.character(at: level) == Char.hash {
            level += 1
        }
        guard (1...6).contains(level), level < ns.length, ns.character(at: level) == Char.space else { return nil }
        return level
    }

    private static func isBulletMarker(_ ns: NSString) -> Bool {
        guard ns.length >= 2 else { return false }
        let first = ns.character(at: 0)
        return (first == Char.hyphen || first == Char.asterisk || first == Char.plus) && ns.character(at: 1) == Char.space
    }

    /// Leading digits, a dot, then a space — `N. `. Returns the marker's
    /// length and the parsed number.
    private static func numberedMarker(_ ns: NSString) -> (length: Int, number: Int)? {
        var index = 0
        while index < ns.length, isDigit(ns.character(at: index)) {
            index += 1
        }
        guard index > 0, index < ns.length, ns.character(at: index) == Char.dot else { return nil }
        let afterDot = index + 1
        guard afterDot < ns.length, ns.character(at: afterDot) == Char.space else { return nil }
        guard let number = Int(ns.substring(to: index)) else { return nil }
        return (afterDot + 1, number)
    }

    private static func isQuoteMarker(_ ns: NSString) -> Bool {
        ns.length >= 2 && ns.character(at: 0) == Char.gt && ns.character(at: 1) == Char.space
    }

    /// Fires the instant the fence's closing backtick is typed and the whole
    /// paragraph reads as exactly ```` ``` ```` plus an optional bare language
    /// word. Because a language word contains no backtick, this can only be
    /// true right when the third backtick lands — typing a language
    /// afterward never re-triggers it. The integration layer decides when
    /// the resulting `.codeBlock` conversion actually takes effect (Typora's
    /// gesture applies it on the following Return, not immediately).
    private static func codeFenceEdit(for context: Context, ns: NSString) -> Edit? {
        guard context.inserted == "`", context.caret == ns.length else { return nil }
        guard let match = fencePattern.firstMatch(in: context.paragraphText, range: NSRange(location: 0, length: ns.length)),
              match.range.length == ns.length
        else { return nil }
        let languageRange = match.range(at: 1)
        let language = languageRange.length > 0 ? ns.substring(with: languageRange) : nil
        return .convertBlock(markerRange: NSRange(location: 0, length: ns.length), kind: .codeBlock(language: language))
    }

    private static let fencePattern = try! NSRegularExpression(pattern: "^```([A-Za-z0-9_+-]*)$")

    private static func inheritedListDepth(_ previousKind: ComposerBlockKind?) -> Int {
        guard let previousKind, previousKind.isList else { return 0 }
        return previousKind.depth
    }

    // MARK: - Inline rules

    private static func inlineEdit(for context: Context) -> Edit? {
        let insertedNS = context.inserted as NSString
        guard insertedNS.length > 0 else { return nil }
        let lastInserted = insertedNS.character(at: insertedNS.length - 1)

        let ns = context.paragraphText as NSString
        guard context.caret >= 1, context.caret <= ns.length else { return nil }

        switch lastInserted {
        case Char.asterisk, Char.underscore:
            return emphasisEdit(context: context, ns: ns, closerChar: lastInserted)
        case Char.backtick:
            return codeSpanEdit(context: context, ns: ns)
        case Char.closeParen:
            return linkEdit(context: context, ns: ns)
        default:
            return nil
        }
    }

    /// `**x**` closes on the second asterisk of a `**` pair; `*x*` and `_x_`
    /// close on a single, unpaired delimiter. Trying bold first means a
    /// completed `**` never falls through and gets misread as two single
    /// closers.
    private static func emphasisEdit(context: Context, ns: NSString, closerChar: unichar) -> Edit? {
        if closerChar == Char.asterisk, context.caret >= 2, ns.character(at: context.caret - 2) == Char.asterisk {
            return boldEdit(ns: ns, caret: context.caret, codeRanges: context.codeRanges)
        }
        let requiresWordBoundary = closerChar == Char.underscore
        return italicEdit(
            ns: ns, caret: context.caret, delimiter: closerChar,
            requiresWordBoundary: requiresWordBoundary, codeRanges: context.codeRanges
        )
    }

    private static func boldEdit(ns: NSString, caret: Int, codeRanges: [NSRange]) -> Edit? {
        let closeRange = NSRange(location: caret - 2, length: 2)
        guard let openerStart = lastDoubleAsterisk(in: ns, endingBefore: closeRange.location) else { return nil }
        let openRange = NSRange(location: openerStart, length: 2)
        guard isValidEmphasis(openRange: openRange, closeRange: closeRange, ns: ns, codeRanges: codeRanges) else { return nil }
        return .convertInline(openRange: openRange, closeRange: closeRange, style: .bold)
    }

    private static func italicEdit(
        ns: NSString, caret: Int, delimiter: unichar, requiresWordBoundary: Bool, codeRanges: [NSRange]
    ) -> Edit? {
        let closeRange = NSRange(location: caret - 1, length: 1)
        guard let openerStart = lastStandaloneDelimiter(delimiter, in: ns, endingBefore: closeRange.location) else { return nil }
        let openRange = NSRange(location: openerStart, length: 1)
        guard isValidEmphasis(openRange: openRange, closeRange: closeRange, ns: ns, codeRanges: codeRanges) else { return nil }

        if requiresWordBoundary {
            let openerPrecededByBoundary = openerStart == 0 || isWhitespace(ns.character(at: openerStart - 1))
            let closerEnd = NSMaxRange(closeRange)
            let closerFollowedByBoundary = closerEnd == ns.length || isWhitespaceOrPunctuation(ns.character(at: closerEnd))
            guard openerPrecededByBoundary, closerFollowedByBoundary else { return nil }
        }
        return .convertInline(openRange: openRange, closeRange: closeRange, style: .italic)
    }

    /// Non-empty content that doesn't start or end with whitespace, and
    /// doesn't reach into an existing code span.
    private static func isValidEmphasis(openRange: NSRange, closeRange: NSRange, ns: NSString, codeRanges: [NSRange]) -> Bool {
        let contentRange = NSRange(location: NSMaxRange(openRange), length: closeRange.location - NSMaxRange(openRange))
        guard contentRange.length > 0 else { return false }
        guard !isWhitespace(ns.character(at: contentRange.location)),
              !isWhitespace(ns.character(at: NSMaxRange(contentRange) - 1))
        else { return false }
        let fullRange = NSRange(location: openRange.location, length: NSMaxRange(closeRange) - openRange.location)
        return !codeRanges.contains { NSIntersectionRange($0, fullRange).length > 0 }
    }

    /// Nearest `**` to the left of `limit`, skipping asterisks that are part
    /// of a `**` already scanned past — irrelevant for the common case, but
    /// keeps a `***triple***` from matching the wrong pair of asterisks.
    private static func lastDoubleAsterisk(in ns: NSString, endingBefore limit: Int) -> Int? {
        var index = limit - 2
        while index >= 0 {
            if ns.character(at: index) == Char.asterisk, ns.character(at: index + 1) == Char.asterisk {
                return index
            }
            index -= 1
        }
        return nil
    }

    /// Nearest occurrence of `delimiter` to the left of `limit` that isn't
    /// adjacent to another asterisk — for `*`, that excludes both asterisks
    /// of an unrelated `**` pair; underscore has no double form to avoid.
    private static func lastStandaloneDelimiter(_ delimiter: unichar, in ns: NSString, endingBefore limit: Int) -> Int? {
        var index = limit - 1
        while index >= 0 {
            if ns.character(at: index) == delimiter {
                if delimiter == Char.asterisk {
                    let precededByAsterisk = index > 0 && ns.character(at: index - 1) == Char.asterisk
                    let followedByAsterisk = index + 1 < ns.length && ns.character(at: index + 1) == Char.asterisk
                    if precededByAsterisk || followedByAsterisk {
                        index -= 1
                        continue
                    }
                }
                return index
            }
            index -= 1
        }
        return nil
    }

    /// `` `x` `` — content must be non-empty, and neither delimiter may be
    /// part of a run of two or more backticks (a fenced-style run isn't a
    /// span this rule handles).
    private static func codeSpanEdit(context: Context, ns: NSString) -> Edit? {
        let closerIndex = context.caret - 1
        guard !(closerIndex > 0 && ns.character(at: closerIndex - 1) == Char.backtick) else { return nil }
        guard !(context.caret < ns.length && ns.character(at: context.caret) == Char.backtick) else { return nil }

        var openerStart = closerIndex - 1
        while openerStart >= 0 {
            if ns.character(at: openerStart) == Char.backtick {
                let precededByBacktick = openerStart > 0 && ns.character(at: openerStart - 1) == Char.backtick
                if precededByBacktick {
                    openerStart -= 1
                    continue
                }
                break
            }
            openerStart -= 1
        }
        guard openerStart >= 0, ns.character(at: openerStart) == Char.backtick else { return nil }

        let openRange = NSRange(location: openerStart, length: 1)
        let closeRange = NSRange(location: closerIndex, length: 1)
        guard closeRange.location > NSMaxRange(openRange) else { return nil }
        return .convertInline(openRange: openRange, closeRange: closeRange, style: .code)
    }

    /// `[text](url)`, closing on `)`. The URL must parse and contain no
    /// spaces (already excluded by the character class below).
    private static func linkEdit(context: Context, ns: NSString) -> Edit? {
        let searched = NSRange(location: 0, length: context.caret)
        guard let match = linkPattern.firstMatch(in: context.paragraphText, range: searched),
              NSMaxRange(match.range) == context.caret
        else { return nil }
        let text = ns.substring(with: match.range(at: 1))
        let urlString = ns.substring(with: match.range(at: 2))
        guard let url = URL(string: urlString) else { return nil }
        return .convertLink(range: match.range, text: text, url: url)
    }

    private static let linkPattern = try! NSRegularExpression(pattern: #"\[([^\[\]\n]+)\]\(([^()\s]+)\)"#)

    // MARK: - Character helpers

    private enum Char {
        static let hash: unichar = 0x23
        static let space: unichar = 0x20
        static let hyphen: unichar = 0x2D
        static let asterisk: unichar = 0x2A
        static let plus: unichar = 0x2B
        static let dot: unichar = 0x2E
        static let gt: unichar = 0x3E
        static let backtick: unichar = 0x60
        static let underscore: unichar = 0x5F
        static let closeParen: unichar = 0x29
    }

    private static func isDigit(_ unit: unichar) -> Bool {
        unit >= 0x30 && unit <= 0x39
    }

    private static func isWhitespace(_ unit: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    private static func isWhitespaceOrPunctuation(_ unit: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar) || CharacterSet.punctuationCharacters.contains(scalar)
    }
}
