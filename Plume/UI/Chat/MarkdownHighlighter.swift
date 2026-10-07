import Foundation

/// Locates markdown syntax spans in raw text for WYSIWYM styling — the
/// composer keeps every marker character in the text (unlike `MarkdownBlock`,
/// which drops them for rendering) and styles them in place, so the text sent
/// to the agent is always exactly what the user typed.
///
/// Ranges are `NSRange` (UTF-16) because the only consumer is
/// `NSTextStorage`, which addresses text in UTF-16 code units. Every range
/// this type produces is derived from `NSString` scanning, never from
/// `String.Index`, so there is no Character/UTF-16 boundary to get wrong.
nonisolated enum MarkdownHighlighter {
    struct Span: Equatable {
        let range: NSRange
        let style: Style
    }

    enum Style: Equatable {
        case bold
        case italic
        case strikethrough
        case inlineCode
        case codeBlock
        case heading(level: Int)
        case listMarker
        case blockQuote
        case link
        /// Inline syntax characters — `**`, `_`, `~~`, backticks, and a
        /// link's brackets and URL — which the composer dims.
        case delimiter
    }

    /// Returns the styled spans in `text`. Spans may overlap (a heading line
    /// also contains its own marker prefix); callers apply them in order and
    /// let later spans win, same as any attribute-run overlay.
    static func spans(in text: String) -> [Span] {
        spans(in: text, lines: MarkdownLineStructure.lines(in: text))
    }

    static func spans(in text: String, lines: [MarkdownLine]) -> [Span] {
        let ns = text as NSString
        var spans: [Span] = []
        var openFenceStart: Int?

        for line in lines {
            switch line.kind {
            case .fence:
                if let start = openFenceStart {
                    spans.append(Span(range: NSRange(location: start, length: NSMaxRange(line.range) - start), style: .codeBlock))
                    openFenceStart = nil
                } else {
                    openFenceStart = line.range.location
                }
            case .code:
                continue
            default:
                lineSpans(in: ns, line: line, into: &spans)
            }
        }
        if let start = openFenceStart {
            spans.append(Span(range: NSRange(location: start, length: ns.length - start), style: .codeBlock))
        }
        return spans
    }

    // MARK: - Line-level markers (heading, list, block quote)

    private static func lineSpans(in ns: NSString, line: MarkdownLine, into spans: inout [Span]) {
        for marker in line.quoteMarkers {
            let quote = ns.range(of: ">", range: marker)
            spans.append(Span(range: quote, style: .blockQuote))
        }

        let contentRange = NSRange(location: line.contentStart, length: NSMaxRange(line.range) - line.contentStart)
        switch line.kind {
        case let .heading(level):
            if let marker = line.marker {
                spans.append(Span(range: marker, style: .heading(level: level)))
            }
            if contentRange.length > 0 {
                spans.append(Span(range: contentRange, style: .heading(level: level)))
            }
        case .bullet, .ordered, .task:
            if let marker = line.marker {
                spans.append(Span(range: marker, style: .listMarker))
            }
        case .rule:
            return
        default:
            break
        }
        if contentRange.length > 0 {
            inlineSpans(in: ns, range: contentRange, into: &spans)
        }
    }

    // MARK: - Inline markers (bold, italic, strikethrough, inline code, links)

    /// Scans `range` for inline code spans first (their contents are
    /// literal), then the other inline styles within the remaining text.
    private static func inlineSpans(in ns: NSString, range: NSRange, into spans: inout [Span]) {
        let codeRanges = inlineCodeSpans(in: ns, range: range, into: &spans)

        var cursor = range.location
        let end = NSMaxRange(range)
        var codeIndex = 0
        var segments: [NSRange] = []
        while cursor < end {
            if codeIndex < codeRanges.count, codeRanges[codeIndex].location == cursor {
                cursor = NSMaxRange(codeRanges[codeIndex])
                codeIndex += 1
                continue
            }
            let nextBoundary = codeIndex < codeRanges.count ? codeRanges[codeIndex].location : end
            if nextBoundary > cursor {
                segments.append(NSRange(location: cursor, length: nextBoundary - cursor))
            }
            cursor = nextBoundary
        }

        for segment in segments {
            linkSpans(in: ns, range: segment, into: &spans)
            strikethroughSpans(in: ns, range: segment, into: &spans)
            emphasisSpans(in: ns, range: segment, into: &spans)
        }
    }

    private static let linkPattern = try! NSRegularExpression(pattern: #"(!?\[)[^\[\]\n]+(\]\([^()\s]+\))"#)

    /// `[text](url)` and `![alt](url)`: one `.link` span over the whole
    /// construct, with the brackets and URL also marked as delimiters.
    private static func linkSpans(in ns: NSString, range: NSRange, into spans: inout [Span]) {
        linkPattern.enumerateMatches(in: ns as String, range: range) { match, _, _ in
            guard let match else { return }
            spans.append(Span(range: match.range, style: .link))
            spans.append(Span(range: match.range(at: 1), style: .delimiter))
            spans.append(Span(range: match.range(at: 2), style: .delimiter))
        }
    }

    private static func inlineCodeSpans(in ns: NSString, range: NSRange, into spans: inout [Span]) -> [NSRange] {
        var ranges: [NSRange] = []
        var cursor = range.location
        let end = NSMaxRange(range)

        while cursor < end {
            guard let backtick = firstUnescaped(ns, char: "`", from: cursor, to: end) else { break }
            guard let closer = firstUnescaped(ns, char: "`", from: backtick + 1, to: end), closer > backtick + 1 else {
                // Unterminated or empty (``) — skip past this backtick, don't style.
                cursor = backtick + 1
                continue
            }
            let codeRange = NSRange(location: backtick, length: closer + 1 - backtick)
            spans.append(Span(range: codeRange, style: .inlineCode))
            spans.append(Span(range: NSRange(location: backtick, length: 1), style: .delimiter))
            spans.append(Span(range: NSRange(location: closer, length: 1), style: .delimiter))
            ranges.append(codeRange)
            cursor = closer + 1
        }
        return ranges
    }

    /// `~~struck~~`. An unterminated `~~` styles nothing.
    private static func strikethroughSpans(in ns: NSString, range: NSRange, into spans: inout [Span]) {
        var cursor = range.location
        let end = NSMaxRange(range)
        while let open = firstUnescapedPair(ns, char: "~", from: cursor, to: end) {
            guard let close = firstUnescapedPair(ns, char: "~", from: open + 2, to: end), close > open + 2 else {
                cursor = open + 2
                continue
            }
            spans.append(Span(range: NSRange(location: open + 2, length: close - open - 2), style: .strikethrough))
            spans.append(Span(range: NSRange(location: open, length: 2), style: .delimiter))
            spans.append(Span(range: NSRange(location: close, length: 2), style: .delimiter))
            cursor = close + 2
        }
    }

    /// `**bold**`, `*italic*`, `_italic_`. A run of markers is scanned
    /// left-to-right and only closes against markers of the same kind and
    /// length, so `**bold *and* italic**` nests correctly and an unterminated
    /// opener styles nothing.
    private static func emphasisSpans(in ns: NSString, range: NSRange, into spans: inout [Span]) {
        var cursor = range.location
        let end = NSMaxRange(range)

        while cursor < end {
            guard let (markerStart, markerChar, markerLen) = nextEmphasisMarker(ns, from: cursor, to: end) else { break }

            guard let closeStart = matchingCloser(ns, char: markerChar, len: markerLen, from: markerStart + markerLen, to: end) else {
                // No closer: this opener is literal text, move past it.
                cursor = markerStart + markerLen
                continue
            }

            let contentStart = markerStart + markerLen
            let contentLength = closeStart - contentStart
            if contentLength == 0 {
                // Empty emphasis (** ** or ****): markers only, no styled content.
                cursor = closeStart + markerLen
                continue
            }

            let style: Style = markerLen == 2 ? .bold : .italic
            let openRange = NSRange(location: markerStart, length: markerLen)
            let contentRange = NSRange(location: contentStart, length: contentLength)
            let closeRange = NSRange(location: closeStart, length: markerLen)

            spans.append(Span(range: openRange, style: style))
            spans.append(Span(range: contentRange, style: style))
            spans.append(Span(range: closeRange, style: style))
            spans.append(Span(range: openRange, style: .delimiter))
            spans.append(Span(range: closeRange, style: .delimiter))

            // Recurse into the content for nested emphasis of the other kind.
            emphasisSpans(in: ns, range: contentRange, into: &spans)

            cursor = closeStart + markerLen
        }
    }

    /// Finds the next `*`, `**`, or `_` run start at or after `from`,
    /// skipping escaped markers (`\*`) entirely.
    private static func nextEmphasisMarker(_ ns: NSString, from: Int, to end: Int) -> (start: Int, char: unichar, len: Int)? {
        var index = from
        while index < end {
            let char = ns.character(at: index)
            if isEscaped(ns, at: index, from: from) {
                index += 1
                continue
            }
            if char == unicharAscii("*") {
                let runLength = (index + 1 < end && ns.character(at: index + 1) == unicharAscii("*")) ? 2 : 1
                return (index, char, runLength)
            }
            if char == unicharAscii("_") {
                return (index, char, 1)
            }
            index += 1
        }
        return nil
    }

    private static func matchingCloser(_ ns: NSString, char: unichar, len: Int, from: Int, to end: Int) -> Int? {
        var index = from
        while index < end {
            let current = ns.character(at: index)
            if isEscaped(ns, at: index, from: from) {
                index += 1
                continue
            }
            if current == char {
                if len == 2 {
                    if index + 1 < end, ns.character(at: index + 1) == char {
                        return index
                    }
                    // Lone marker where we need a double — not a closer.
                    index += 1
                    continue
                }
                // len == 1: a `*` closer must not be immediately followed by
                // another `*` (that would be the closer of a `**` pair).
                if char == unicharAscii("*"), index + 1 < end, ns.character(at: index + 1) == unicharAscii("*") {
                    index += 2
                    continue
                }
                return index
            }
            index += 1
        }
        return nil
    }

    private static func firstUnescaped(_ ns: NSString, char: Character, from: Int, to end: Int) -> Int? {
        let scalar = char.unicodeScalars.first.map { unichar($0.value) } ?? 0
        var index = from
        while index < end {
            if ns.character(at: index) == scalar, !isEscaped(ns, at: index, from: from) {
                return index
            }
            index += 1
        }
        return nil
    }

    private static func firstUnescapedPair(_ ns: NSString, char: Character, from: Int, to end: Int) -> Int? {
        var cursor = from
        while let index = firstUnescaped(ns, char: char, from: cursor, to: end) {
            if index + 1 < end, ns.character(at: index + 1) == ns.character(at: index) {
                return index
            }
            cursor = index + 1
        }
        return nil
    }

    /// A marker is escaped when preceded by an odd number of backslashes,
    /// counted only back to `boundary` so escapes never look across a
    /// segment we've already consumed (e.g. past a closed code span).
    private static func isEscaped(_ ns: NSString, at index: Int, from boundary: Int) -> Bool {
        var backslashes = 0
        var cursor = index - 1
        while cursor >= boundary, ns.character(at: cursor) == unicharAscii("\\") {
            backslashes += 1
            cursor -= 1
        }
        return backslashes % 2 == 1
    }
}

private func unicharAscii(_ scalar: Unicode.Scalar) -> unichar {
    unichar(scalar.value)
}
