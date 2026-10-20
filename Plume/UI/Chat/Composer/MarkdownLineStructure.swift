import Foundation

/// One line of composer markdown, split into the prefix the composer draws
/// over and the content after it.
///
/// Ranges are UTF-16 offsets into the whole text, matching `NSTextStorage`.
nonisolated struct MarkdownLine: Equatable {
    enum Kind: Equatable {
        case plain
        case blank
        case heading(level: Int)
        case bullet
        case ordered(number: Int)
        case task(isChecked: Bool)
        case rule
        /// An opening or closing fence line.
        case fence
        /// A line inside a fenced block.
        case code
    }

    /// The line's text, without its terminator.
    var range: NSRange
    var kind: Kind
    /// Each `>` with the space after it, outermost first.
    var quoteMarkers: [NSRange] = []
    /// The spaces and tabs after the quote markers.
    var indent: NSRange
    /// `- `, `12. `, `- [ ] `, `## `, or a rule's whole text. Nil for a line
    /// with no marker.
    var marker: NSRange?
    /// A task item's `[ ]` or `[x]`.
    var checkbox: NSRange?
    /// Nesting below the outermost list item at the same quote level.
    var depth = 0

    var contentStart: Int { marker.map(NSMaxRange) ?? NSMaxRange(indent) }
    var quoteLevel: Int { quoteMarkers.count }
    var prefixStart: Int { range.location }

    var isListItem: Bool {
        switch kind {
        case .bullet, .ordered, .task: true
        default: false
        }
    }

    /// Whether the marker is drawn over rather than shown: bullets, task
    /// boxes and rules. Quote markers are always hidden too.
    var hidesMarker: Bool {
        switch kind {
        case .bullet, .task, .rule: true
        default: false
        }
    }

    /// The characters the caret skips as one unit: quote markers, the
    /// indent, and a hidden marker. Shown markers and plain indents only
    /// count when a quote precedes them.
    var atomicPrefix: NSRange? {
        let end = hidesMarker ? contentStart : (quoteMarkers.last.map(NSMaxRange) ?? range.location)
        guard end > range.location else { return nil }
        return NSRange(location: range.location, length: end - range.location)
    }
}

/// Splits composer text into `MarkdownLine`s.
///
/// Fences follow CommonMark: a run of three or more backticks or tildes
/// opens a block that only an equal or longer run of the same character
/// closes, and an unclosed block runs to the end of the text, the way the
/// chat's `MarkdownBlock` renders it.
nonisolated enum MarkdownLineStructure {
    static func lines(in text: String) -> [MarkdownLine] {
        let ns = text as NSString
        var result: [MarkdownLine] = []
        var openFence: (character: unichar, length: Int, quoteLevel: Int)?
        var listStack: [(quoteLevel: Int, indentColumns: Int)] = []

        for lineRange in lineRanges(in: ns) {
            var cursor = lineRange.location
            let end = NSMaxRange(lineRange)

            // Inside a fence, a `>` past the fence's own quote level is code.
            let quoteLimit = openFence?.quoteLevel ?? .max
            var quoteMarkers: [NSRange] = []
            while quoteMarkers.count < quoteLimit, let marker = quoteMarker(in: ns, at: cursor, end: end) {
                quoteMarkers.append(marker)
                cursor = NSMaxRange(marker)
            }

            let indentStart = cursor
            var indentColumns = 0
            while cursor < end, let width = whitespaceWidth(ns.character(at: cursor)) {
                indentColumns += width
                cursor += 1
            }
            var line = MarkdownLine(
                range: lineRange,
                kind: .plain,
                quoteMarkers: quoteMarkers,
                indent: NSRange(location: indentStart, length: cursor - indentStart)
            )
            let body = NSRange(location: cursor, length: end - cursor)

            if let fence = openFence {
                if let run = fenceRun(in: ns, body), run.character == fence.character, run.length >= fence.length,
                   run.trailingIsBlank {
                    line.kind = .fence
                    openFence = nil
                } else {
                    line.kind = .code
                }
                result.append(line)
                continue
            }

            if let run = fenceRun(in: ns, body) {
                line.kind = .fence
                openFence = (run.character, run.length, quoteMarkers.count)
                listStack.removeAll()
                result.append(line)
                continue
            }

            if body.length == 0 {
                line.kind = .blank
                result.append(line)
                continue
            }

            if let level = headingLevel(in: ns, body) {
                line.kind = .heading(level: level)
                let markerLength = min(level + 1, body.length)
                line.marker = NSRange(location: body.location, length: markerLength)
                listStack.removeAll()
            } else if isRule(ns.substring(with: body)) {
                line.kind = .rule
                line.marker = body
                listStack.removeAll()
            } else if let item = listItem(in: ns, body) {
                line.kind = item.kind
                line.marker = item.marker
                line.checkbox = item.checkbox
                while let top = listStack.last,
                      top.quoteLevel > line.quoteLevel || (top.quoteLevel == line.quoteLevel && top.indentColumns >= indentColumns) {
                    listStack.removeLast()
                }
                line.depth = listStack.count(where: { $0.quoteLevel == line.quoteLevel })
                listStack.append((line.quoteLevel, indentColumns))
            } else if indentColumns == 0 {
                listStack.removeAll { $0.quoteLevel >= line.quoteLevel }
            }
            result.append(line)
        }
        return result
    }

    /// The line containing `location`, or the last line when `location` is
    /// the end of the text.
    static func line(containing location: Int, in lines: [MarkdownLine]) -> MarkdownLine? {
        lines.last { $0.range.location <= location }
    }

    /// Whether a whitespace-trimmed line is a thematic break: three or more
    /// of one of `-`, `*`, `_`, optionally spaced out.
    static func isRule(_ trimmed: String) -> Bool {
        let compact = trimmed.filter { $0 != " " && $0 != "\t" }
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first } && trimmed.first == first
    }

    // MARK: - Lines

    /// Every line, including the empty one after a trailing newline, so the
    /// caret's line always exists.
    private static func lineRanges(in ns: NSString) -> [NSRange] {
        var ranges: [NSRange] = []
        var start = 0
        while start < ns.length {
            var lineEnd = 0
            var contentsEnd = 0
            ns.getLineStart(nil, end: &lineEnd, contentsEnd: &contentsEnd, for: NSRange(location: start, length: 0))
            ranges.append(NSRange(location: start, length: contentsEnd - start))
            start = lineEnd
        }
        if ns.length == 0 || isNewline(ns.character(at: ns.length - 1)) {
            ranges.append(NSRange(location: ns.length, length: 0))
        }
        return ranges
    }

    private static func quoteMarker(in ns: NSString, at location: Int, end: Int) -> NSRange? {
        var cursor = location
        while cursor < end, cursor - location < 3, ns.character(at: cursor) == space {
            cursor += 1
        }
        guard cursor < end, ns.character(at: cursor) == ascii(">") else { return nil }
        let length = cursor + 1 < end && ns.character(at: cursor + 1) == space ? 2 : 1
        return NSRange(location: location, length: cursor - location + length)
    }

    private static func fenceRun(in ns: NSString, _ body: NSRange) -> (character: unichar, length: Int, trailingIsBlank: Bool)? {
        guard body.length >= 3 else { return nil }
        let first = ns.character(at: body.location)
        guard first == ascii("`") || first == ascii("~") else { return nil }
        var length = 0
        while length < body.length, ns.character(at: body.location + length) == first {
            length += 1
        }
        guard length >= 3 else { return nil }
        let rest = ns.substring(with: NSRange(location: body.location + length, length: body.length - length))
        return (first, length, rest.allSatisfy { $0 == " " || $0 == "\t" })
    }

    private static func headingLevel(in ns: NSString, _ body: NSRange) -> Int? {
        var level = 0
        while level < body.length, level < 7, ns.character(at: body.location + level) == ascii("#") {
            level += 1
        }
        guard (1...6).contains(level) else { return nil }
        if level == body.length { return level }
        return ns.character(at: body.location + level) == space ? level : nil
    }

    private static func listItem(in ns: NSString, _ body: NSRange) -> (kind: MarkdownLine.Kind, marker: NSRange, checkbox: NSRange?)? {
        let first = ns.character(at: body.location)
        if first == ascii("-") || first == ascii("*") || first == ascii("+") {
            guard body.length >= 2, ns.character(at: body.location + 1) == space else { return nil }
            let bullet = NSRange(location: body.location, length: 2)
            if let task = taskBox(in: ns, after: NSMaxRange(bullet), end: NSMaxRange(body)) {
                let marker = NSRange(location: body.location, length: task.markerEnd - body.location)
                return (.task(isChecked: task.isChecked), marker, task.box)
            }
            return (.bullet, bullet, nil)
        }

        var digits = 0
        while digits < body.length, digits < 9, isDigit(ns.character(at: body.location + digits)) {
            digits += 1
        }
        guard digits > 0, digits + 1 < body.length else { return nil }
        let delimiter = ns.character(at: body.location + digits)
        guard delimiter == ascii(".") || delimiter == ascii(")"),
              ns.character(at: body.location + digits + 1) == space,
              let number = Int(ns.substring(with: NSRange(location: body.location, length: digits)))
        else { return nil }
        return (.ordered(number: number), NSRange(location: body.location, length: digits + 2), nil)
    }

    private static func taskBox(in ns: NSString, after location: Int, end: Int) -> (box: NSRange, isChecked: Bool, markerEnd: Int)? {
        guard end - location >= 3,
              ns.character(at: location) == ascii("["),
              ns.character(at: location + 2) == ascii("]")
        else { return nil }
        let mark = ns.character(at: location + 1)
        let isChecked: Bool
        switch mark {
        case space: isChecked = false
        case ascii("x"), ascii("X"): isChecked = true
        default: return nil
        }
        let boxEnd = location + 3
        if boxEnd == end { return (NSRange(location: location, length: 3), isChecked, boxEnd) }
        guard ns.character(at: boxEnd) == space else { return nil }
        return (NSRange(location: location, length: 3), isChecked, boxEnd + 1)
    }

    // MARK: - Characters

    private static let space = unichar(0x20)

    private static func whitespaceWidth(_ unit: unichar) -> Int? {
        switch unit {
        case 0x20: 1
        case 0x09: 4
        default: nil
        }
    }

    private static func isNewline(_ unit: unichar) -> Bool {
        unit == 0x0A || unit == 0x0D || unit == 0x2028 || unit == 0x2029
    }

    private static func isDigit(_ unit: unichar) -> Bool {
        unit >= ascii("0") && unit <= ascii("9")
    }

    private static func ascii(_ scalar: Unicode.Scalar) -> unichar {
        unichar(scalar.value)
    }
}
