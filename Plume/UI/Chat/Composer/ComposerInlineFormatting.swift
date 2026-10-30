import Foundation

/// The composer's ⌘B, ⌘I, ⌘E and ⌘K, as pure text transforms. The text stays
/// plain markdown: each key adds or removes characters and never styles.
///
/// | Selection | Result |
/// | --- | --- |
/// | text | wrapped; text already wrapped, or including its markers, is unwrapped |
/// | caret inside or at the end of a word | the word is wrapped |
/// | caret elsewhere, or at a word's leading edge | an empty pair, caret between |
/// | caret inside an empty pair | the pair is removed |
///
/// Bold, italic and link leave code and fence lines alone (nil).
nonisolated enum ComposerInlineFormatting {
    enum Style: Equatable {
        case bold, italic, code, link

        var marker: String {
            switch self {
            case .bold: "**"
            case .italic: "*"
            case .code: "`"
            case .link: ""
            }
        }

        init?(characters: String) {
            switch characters {
            case "b": self = .bold
            case "i": self = .italic
            case "e": self = .code
            case "k": self = .link
            default: return nil
            }
        }
    }

    static func apply(_ style: Style, in text: String, selection: NSRange) -> ComposerMarkdownEditing.Result? {
        let ns = text as NSString
        guard NSMaxRange(selection) <= ns.length else { return nil }
        if style != .code, touchesCode(selection, in: text) { return nil }
        return style == .link ? link(in: ns, selection: selection) : toggle(style.marker, in: ns, selection: selection)
    }

    // MARK: - Emphasis and code

    private static func toggle(_ marker: String, in ns: NSString, selection: NSRange) -> ComposerMarkdownEditing.Result {
        let width = (marker as NSString).length
        if selection.length == 0 {
            if let removed = unwrapEmptyPair(marker, in: ns, caret: selection.location) { return removed }
            guard let word = wordRange(containing: selection.location, in: ns) else {
                let text = ns.replacingCharacters(in: selection, with: marker + marker)
                return .init(text: text, selection: NSRange(location: selection.location + width, length: 0))
            }
            let text = wrapped(marker, around: word, in: ns)
            return .init(text: text, selection: NSRange(location: NSMaxRange(word) + 2 * width, length: 0))
        }
        if let inner = wrappedInner(marker, around: selection, in: ns) {
            let outer = NSRange(location: inner.location - width, length: inner.length + 2 * width)
            let text = ns.replacingCharacters(in: outer, with: ns.substring(with: inner))
            return .init(text: text, selection: NSRange(location: outer.location, length: inner.length))
        }
        return .init(
            text: wrapped(marker, around: selection, in: ns),
            selection: NSRange(location: selection.location + width, length: selection.length)
        )
    }

    private static func wrapped(_ marker: String, around range: NSRange, in ns: NSString) -> String {
        ns.replacingCharacters(in: range, with: marker + ns.substring(with: range) + marker)
    }

    private static func unwrapEmptyPair(_ marker: String, in ns: NSString, caret: Int) -> ComposerMarkdownEditing.Result? {
        let width = (marker as NSString).length
        let pair = NSRange(location: caret - width, length: 2 * width)
        guard pair.location >= 0, NSMaxRange(pair) <= ns.length,
              ns.substring(with: pair) == marker + marker,
              !extendsMarkerRun(marker, around: pair, in: ns)
        else { return nil }
        return .init(text: ns.replacingCharacters(in: pair, with: ""), selection: NSRange(location: pair.location, length: 0))
    }

    /// The range between a pair of `marker`s that sit just outside `range`,
    /// or are its first and last characters.
    private static func wrappedInner(_ marker: String, around range: NSRange, in ns: NSString) -> NSRange? {
        let width = (marker as NSString).length
        func isMarker(at location: Int) -> Bool {
            location >= 0 && location + width <= ns.length
                && ns.substring(with: NSRange(location: location, length: width)) == marker
        }
        if range.length >= 2 * width, isMarker(at: range.location), isMarker(at: NSMaxRange(range) - width),
           !extendsMarkerRun(marker, around: range, in: ns) {
            return NSRange(location: range.location + width, length: range.length - 2 * width)
        }
        let outer = NSRange(location: range.location - width, length: range.length + 2 * width)
        guard isMarker(at: range.location - width), isMarker(at: NSMaxRange(range)),
              !extendsMarkerRun(marker, around: outer, in: ns)
        else { return nil }
        return range
    }

    /// Whether another `*` touches `outer`, so a single `*` pair would be
    /// half of a bold pair rather than italic.
    private static func extendsMarkerRun(_ marker: String, around outer: NSRange, in ns: NSString) -> Bool {
        guard marker == "*" else { return false }
        let star = unichar(UInt8(ascii: "*"))
        let before = outer.location > 0 ? ns.character(at: outer.location - 1) : 0
        let after = NSMaxRange(outer) < ns.length ? ns.character(at: NSMaxRange(outer)) : 0
        return before == star || after == star
    }

    // MARK: - Link

    /// A URL selection becomes the link's target with the caret in the label;
    /// anything else becomes the label with the caret in the target.
    private static func link(in ns: NSString, selection: NSRange) -> ComposerMarkdownEditing.Result {
        let target = selection.length > 0 ? selection : (wordRange(containing: selection.location, in: ns) ?? selection)
        guard target.length > 0 else {
            return .init(
                text: ns.replacingCharacters(in: selection, with: "[]()"),
                selection: NSRange(location: selection.location + 1, length: 0)
            )
        }
        let label = ns.substring(with: target)
        if label.hasPrefix("http://") || label.hasPrefix("https://") {
            return .init(
                text: ns.replacingCharacters(in: target, with: "[](\(label))"),
                selection: NSRange(location: target.location + 1, length: 0)
            )
        }
        return .init(
            text: ns.replacingCharacters(in: target, with: "[\(label)]()"),
            selection: NSRange(location: target.location + (label as NSString).length + 3, length: 0)
        )
    }

    // MARK: - Words and code

    /// The word the caret is inside or at the end of; nil at a leading edge or
    /// between non-word characters.
    static func wordRange(containing caret: Int, in ns: NSString) -> NSRange? {
        guard caret > 0, caret <= ns.length, isWordCharacter(ns.character(at: caret - 1)) else { return nil }
        var start = caret - 1
        while start > 0, isWordCharacter(ns.character(at: start - 1)) { start -= 1 }
        var end = caret
        while end < ns.length, isWordCharacter(ns.character(at: end)) { end += 1 }
        return NSRange(location: start, length: end - start)
    }

    private static func isWordCharacter(_ unit: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return true }
        return CharacterSet.alphanumerics.contains(scalar) || scalar == "_"
    }

    private static func touchesCode(_ selection: NSRange, in text: String) -> Bool {
        MarkdownLineStructure.lines(in: text).contains { line in
            guard line.kind == .code || line.kind == .fence else { return false }
            let reach = NSRange(location: line.range.location, length: line.range.length + 1)
            return NSLocationInRange(selection.location, reach) || NSLocationInRange(NSMaxRange(selection), reach)
        }
    }
}
