import Foundation

/// Locates markdown syntax spans in raw text for WYSIWYM styling — the
/// composer keeps every marker character on screen (unlike `MarkdownBlock`,
/// which drops them for rendering) and merely styles them in place, so the
/// text sent to the agent is always exactly what the user typed.
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
        case inlineCode
        case codeBlock
        case heading(level: Int)
        case listMarker
        case blockQuote
        case link
    }

    /// Returns the styled spans in `text`. Spans may overlap (a heading line
    /// also contains its own marker prefix); callers apply them in order and
    /// let later spans win, same as any attribute-run overlay.
    static func spans(in text: String) -> [Span] {
        let ns = text as NSString
        var spans: [Span] = []

        let codeBlockRanges = codeBlockSpans(in: ns, into: &spans)

        let fullRange = NSRange(location: 0, length: ns.length)
        for lineRange in lineRanges(in: ns, within: fullRange) {
            if codeBlockRanges.contains(where: { NSIntersectionRange($0, lineRange).length > 0 || $0.contains(lineRange) }) {
                continue
            }
            lineSpans(in: ns, lineRange: lineRange, into: &spans)
        }

        return spans
    }

    // MARK: - Code blocks (```...```)

    /// Fenced code blocks are found first because their contents are literal
    /// text — no other marker inside them should be styled.
    private static func codeBlockSpans(in ns: NSString, into spans: inout [Span]) -> [NSRange] {
        var ranges: [NSRange] = []
        let fencePattern = try! NSRegularExpression(pattern: "^(```|~~~).*$", options: [.anchorsMatchLines])
        let fullRange = NSRange(location: 0, length: ns.length)
        let fenceMatches = fencePattern.matches(in: ns as String, range: fullRange)

        var index = 0
        while index < fenceMatches.count {
            let open = fenceMatches[index]
            guard let closeIndex = (index + 1..<fenceMatches.count).first else {
                index += 1
                continue
            }
            let close = fenceMatches[closeIndex]
            let blockRange = NSRange(location: open.range.location, length: NSMaxRange(close.range) - open.range.location)
            spans.append(Span(range: blockRange, style: .codeBlock))
            ranges.append(blockRange)
            index = closeIndex + 1
        }
        return ranges
    }

    // MARK: - Line splitting

    private static func lineRanges(in ns: NSString, within range: NSRange) -> [NSRange] {
        var result: [NSRange] = []
        ns.enumerateSubstrings(in: range, options: [.byLines, .substringNotRequired]) { _, substringRange, _, _ in
            result.append(substringRange)
        }
        return result
    }

    // MARK: - Line-level markers (heading, list, block quote)

    private static func lineSpans(in ns: NSString, lineRange: NSRange, into spans: inout [Span]) {
        let line = ns.substring(with: lineRange)
        let leadingWhitespace = line.prefix { $0 == " " || $0 == "\t" }
        let indent = (leadingWhitespace as NSString).length
        let trimmed = String(line.dropFirst(leadingWhitespace.count))
        let trimmedNS = trimmed as NSString

        if let headingMatch = headingPrefix(trimmedNS) {
            let level = headingMatch
            let markerLength = level + (trimmedNS.length > level && trimmedNS.character(at: level) == 0x20 ? 1 : 0)
            let markerRange = NSRange(location: lineRange.location + indent, length: markerLength)
            spans.append(Span(range: markerRange, style: .heading(level: level)))
            let restRange = NSRange(
                location: lineRange.location + indent + markerLength,
                length: lineRange.length - indent - markerLength
            )
            if restRange.length > 0 {
                spans.append(Span(range: restRange, style: .heading(level: level)))
                inlineSpans(in: ns, range: restRange, into: &spans)
            }
            return
        }

        if trimmedNS.length > 0, trimmedNS.character(at: 0) == unicharAscii(">") {
            let markerRange = NSRange(location: lineRange.location + indent, length: 1)
            spans.append(Span(range: markerRange, style: .blockQuote))
            let afterMarker = markerRange.location + 1
            let contentRange = NSRange(location: afterMarker, length: NSMaxRange(lineRange) - afterMarker)
            inlineSpans(in: ns, range: contentRange, into: &spans)
            return
        }

        if let markerLength = bulletMarkerLength(trimmedNS) {
            let markerRange = NSRange(location: lineRange.location + indent, length: markerLength)
            spans.append(Span(range: markerRange, style: .listMarker))
            let afterMarker = markerRange.location + markerLength
            let contentRange = NSRange(location: afterMarker, length: NSMaxRange(lineRange) - afterMarker)
            inlineSpans(in: ns, range: contentRange, into: &spans)
            return
        }

        if let markerLength = numberedMarkerLength(trimmedNS) {
            let markerRange = NSRange(location: lineRange.location + indent, length: markerLength)
            spans.append(Span(range: markerRange, style: .listMarker))
            let afterMarker = markerRange.location + markerLength
            let contentRange = NSRange(location: afterMarker, length: NSMaxRange(lineRange) - afterMarker)
            inlineSpans(in: ns, range: contentRange, into: &spans)
            return
        }

        inlineSpans(in: ns, range: lineRange, into: &spans)
    }

    private static func headingPrefix(_ line: NSString) -> Int? {
        var level = 0
        while level < line.length, level < 6, line.character(at: level) == unicharAscii("#") {
            level += 1
        }
        guard level > 0 else { return nil }
        if level == line.length { return level }
        return line.character(at: level) == 0x20 ? level : nil
    }

    private static func bulletMarkerLength(_ line: NSString) -> Int? {
        guard line.length >= 2 else { return nil }
        let first = line.character(at: 0)
        guard first == unicharAscii("-") || first == unicharAscii("*") || first == unicharAscii("+") else { return nil }
        return line.character(at: 1) == 0x20 ? 2 : nil
    }

    private static func numberedMarkerLength(_ line: NSString) -> Int? {
        var index = 0
        while index < line.length, isDigit(line.character(at: index)) {
            index += 1
        }
        guard index > 0, index < line.length, line.character(at: index) == unicharAscii(".") else { return nil }
        let afterDot = index + 1
        guard afterDot < line.length, line.character(at: afterDot) == 0x20 else { return nil }
        return afterDot + 1
    }

    private static func isDigit(_ unit: unichar) -> Bool {
        unit >= unicharAscii("0") && unit <= unicharAscii("9")
    }

    // MARK: - Inline markers (bold, italic, inline code, escapes)

    /// Scans `range` for inline code spans first (their contents are
    /// literal), then bold/italic within the remaining, non-code text.
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
            emphasisSpans(in: ns, range: segment, into: &spans)
        }
    }

    private static let linkPattern = try! NSRegularExpression(pattern: #"\[[^\[\]\n]+\]\([^()\s]+\)"#)

    /// `[text](url)` styled as a single span covering the whole construct,
    /// including its brackets — the composer isn't a rich editor, so the
    /// link markup itself is the content worth dimming-and-tinting, not a
    /// hidden-vs-shown split.
    private static func linkSpans(in ns: NSString, range: NSRange, into spans: inout [Span]) {
        linkPattern.enumerateMatches(in: ns as String, range: range) { match, _, _ in
            guard let match else { return }
            spans.append(Span(range: match.range, style: .link))
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
            ranges.append(codeRange)
            cursor = closer + 1
        }
        return ranges
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

private extension NSRange {
    func contains(_ other: NSRange) -> Bool {
        location <= other.location && NSMaxRange(self) >= NSMaxRange(other)
    }
}

private func unicharAscii(_ scalar: Unicode.Scalar) -> unichar {
    unichar(scalar.value)
}
