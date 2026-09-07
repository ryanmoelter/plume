import Foundation

/// A single block-level element of parsed markdown.
///
/// `AttributedString(markdown:)` handles inline formatting (bold, italic,
/// inline code, links) but has no notion of block structure — headings,
/// fenced code, lists, quotes. `parse(_:)` splits the raw text into blocks
/// by hand; `MarkdownView` then inline-parses each paragraph and list item.
///
/// Deliberately unsupported: nested lists. Their raw lines fall through to
/// `.paragraph` rather than being mangled or dropped.
nonisolated enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bulletList([String])
    /// `start` is the number the source's first item carried, so a list
    /// beginning at 3 keeps counting from 3.
    case numberedList([String], start: Int)
    case codeBlock(language: String?, code: String)
    case quote(String)
    case table(header: [String], alignments: [ColumnAlignment], rows: [[String]])
    case rule

    /// How a column's cells sit in their width, from the `:` markers in a
    /// table's delimiter row.
    nonisolated enum ColumnAlignment: Equatable {
        case leading
        case center
        case trailing
    }

    /// A short name for the case, for the chat list's stats probe.
    var kindName: String {
        switch self {
        case .heading: "heading"
        case .paragraph: "paragraph"
        case .bulletList: "bulletList"
        case .numberedList: "numberedList"
        case .codeBlock: "codeBlock"
        case .quote: "quote"
        case .table: "table"
        case .rule: "rule"
        }
    }

    /// Whether a table's header carries anything worth showing.
    ///
    /// An all-empty header is the key-value form of a table, where a blank
    /// row and its rule would float a line above nothing.
    static func headerIsMeaningful(_ header: [String]) -> Bool {
        header.contains { !$0.isEmpty }
    }

    /// A block alongside the raw lines it was parsed from.
    ///
    /// The streaming overlay needs the source of the block still growing, so
    /// the settled ones can be handed to the list as ordinary pieces while
    /// only the tail keeps revealing.
    nonisolated struct Parsed: Equatable {
        let block: MarkdownBlock
        let source: String
    }

    static func parse(_ text: String) -> [MarkdownBlock] {
        parseWithSources(text).map(\.block)
    }

    static func parseWithSources(_ text: String) -> [Parsed] {
        let lines = text.components(separatedBy: "\n")
        var blocks: [Parsed] = []
        var index = 0

        func append(_ block: MarkdownBlock, from start: Int, to end: Int) {
            let lower = min(max(0, start), lines.count)
            let bounded = lower..<max(lower, min(end, lines.count))
            blocks.append(Parsed(
                block: block,
                source: bounded.isEmpty ? "" : lines[bounded].joined(separator: "\n")
            ))
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                index += 1
                continue
            }

            if let fence = fenceMarker(trimmed) {
                let language = fence.language.isEmpty ? nil : fence.language
                var codeLines: [String] = []
                var cursor = index + 1
                while cursor < lines.count {
                    let candidate = lines[cursor].trimmingCharacters(in: .whitespaces)
                    if candidate.hasPrefix(fence.token) {
                        break
                    }
                    codeLines.append(lines[cursor])
                    cursor += 1
                }
                // Unterminated fence: cursor ran off the end. Keep the
                // captured content instead of discarding it.
                append(
                    .codeBlock(language: language, code: codeLines.joined(separator: "\n")),
                    from: index,
                    to: cursor + 1
                )
                index = cursor + 1
                continue
            }

            if let level = headingLevel(trimmed) {
                let text = String(trimmed.dropFirst(level)).trimmingCharacters(in: .whitespaces)
                append(.heading(level: level, text: text), from: index, to: index + 1)
                index += 1
                continue
            }

            // Before `isRule`, so a delimiter row is never mistaken for one.
            if let table = tableAt(index, in: lines) {
                append(table.block, from: index, to: table.nextIndex)
                index = table.nextIndex
                continue
            }

            if isRule(trimmed) {
                append(.rule, from: index, to: index + 1)
                index += 1
                continue
            }

            if trimmed.hasPrefix(">") {
                var quoteLines: [String] = []
                var cursor = index
                while cursor < lines.count {
                    let candidate = lines[cursor].trimmingCharacters(in: .whitespaces)
                    guard candidate.hasPrefix(">") else { break }
                    quoteLines.append(String(candidate.dropFirst()).trimmingCharacters(in: .whitespaces))
                    cursor += 1
                }
                append(.quote(quoteLines.joined(separator: "\n")), from: index, to: cursor)
                index = cursor
                continue
            }

            if let list = list(startingAt: index, in: lines, kind: .bullet) {
                append(.bulletList(list.items), from: index, to: list.end)
                index = list.end
                continue
            }

            if let list = list(startingAt: index, in: lines, kind: .numbered) {
                append(.numberedList(list.items, start: list.start), from: index, to: list.end)
                index = list.end
                continue
            }

            // Paragraph: collect consecutive non-blank, non-block-marker lines.
            var paragraphLines: [String] = []
            var cursor = index
            while cursor < lines.count {
                let candidate = lines[cursor]
                let candidateTrimmed = candidate.trimmingCharacters(in: .whitespaces)
                if candidateTrimmed.isEmpty
                    || fenceMarker(candidateTrimmed) != nil
                    || headingLevel(candidateTrimmed) != nil
                    || tableAt(cursor, in: lines) != nil
                    || isRule(candidateTrimmed)
                    || candidateTrimmed.hasPrefix(">")
                    || bulletItemText(candidateTrimmed) != nil
                    || numberedItemText(candidateTrimmed) != nil {
                    break
                }
                paragraphLines.append(candidate)
                cursor += 1
            }
            append(.paragraph(paragraphLines.joined(separator: "\n")), from: index, to: cursor)
            index = cursor
        }

        return blocks
    }

    private static func fenceMarker(_ trimmed: String) -> (token: String, language: String)? {
        for token in ["```", "~~~"] {
            if trimmed.hasPrefix(token) {
                let language = String(trimmed.dropFirst(token.count)).trimmingCharacters(in: .whitespaces)
                return (token, language)
            }
        }
        return nil
    }

    /// A table starting at `index`, or nil if the lines there aren't one.
    ///
    /// Needs two lines to decide: a lone pipe-bearing line is prose, so the
    /// delimiter row underneath is what distinguishes `a | b` in a sentence
    /// from a real header.
    private static func tableAt(
        _ index: Int,
        in lines: [String]
    ) -> (block: MarkdownBlock, nextIndex: Int)? {
        guard index + 1 < lines.count else { return nil }
        let headerLine = lines[index].trimmingCharacters(in: .whitespaces)
        let delimiterLine = lines[index + 1].trimmingCharacters(in: .whitespaces)
        guard headerLine.contains("|"), isDelimiterRow(delimiterLine) else { return nil }

        let header = rowCells(headerLine)
        let alignments = rowCells(delimiterLine).map(alignment(ofDelimiter:))
        // GFM requires the two to agree; when they don't it isn't a table.
        guard alignments.count == header.count else { return nil }

        var rows: [[String]] = []
        var cursor = index + 2
        while cursor < lines.count {
            let candidate = lines[cursor].trimmingCharacters(in: .whitespaces)
            guard !candidate.isEmpty, candidate.contains("|") else { break }
            rows.append(fitting(rowCells(candidate), to: header.count))
            cursor += 1
        }

        return (.table(header: header, alignments: alignments, rows: rows), cursor)
    }

    private static func isDelimiterRow(_ trimmed: String) -> Bool {
        guard trimmed.contains("-") else { return false }
        return trimmed.allSatisfy { $0 == "-" || $0 == ":" || $0 == "|" || $0 == " " }
    }

    /// A row's cells, less the empty fields that a leading or trailing pipe
    /// produces — `| a | b |` and `a | b` are both legal and equivalent.
    private static func rowCells(_ trimmed: String) -> [String] {
        var cells = splitOnUnescapedPipes(trimmed)
        if let first = cells.first, first.trimmingCharacters(in: .whitespaces).isEmpty,
           trimmed.hasPrefix("|") {
            cells.removeFirst()
        }
        if let last = cells.last, last.trimmingCharacters(in: .whitespaces).isEmpty,
           trimmed.hasSuffix("|"), !trimmed.hasSuffix("\\|") {
            cells.removeLast()
        }
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Splits on `|` while treating `\|` as a literal pipe, unescaping it in
    /// place so the backslash never reaches the rendered cell.
    private static func splitOnUnescapedPipes(_ text: String) -> [String] {
        var cells: [String] = []
        var current = ""
        var escaped = false
        for character in text {
            if escaped {
                // Only `\|` is ours; any other escape belongs to the inline
                // parser and keeps its backslash.
                if character != "|" { current.append("\\") }
                current.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "|" {
                cells.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        if escaped { current.append("\\") }
        cells.append(current)
        return cells
    }

    private static func alignment(ofDelimiter cell: String) -> ColumnAlignment {
        let trimmed = cell.trimmingCharacters(in: .whitespaces)
        switch (trimmed.hasPrefix(":"), trimmed.hasSuffix(":")) {
        case (true, true): return .center
        case (false, true): return .trailing
        default: return .leading
        }
    }

    /// A ragged row still renders: pad a short one, drop a long one's excess.
    private static func fitting(_ cells: [String], to count: Int) -> [String] {
        if cells.count == count { return cells }
        if cells.count < count {
            return cells + Array(repeating: "", count: count - cells.count)
        }
        return Array(cells.prefix(count))
    }

    private static func headingLevel(_ trimmed: String) -> Int? {
        guard trimmed.hasPrefix("#") else { return nil }
        let level = trimmed.prefix { $0 == "#" }.count
        guard level <= 6 else { return nil }
        let rest = trimmed.dropFirst(level)
        // Require a space (or end of line) after the hashes, else it's not a heading.
        guard rest.isEmpty || rest.hasPrefix(" ") else { return nil }
        return level
    }

    private static func isRule(_ trimmed: String) -> Bool {
        for marker: Character in ["-", "*", "_"] {
            let stripped = trimmed.filter { $0 == marker }
            if stripped.count >= 3 && stripped.count == trimmed.replacingOccurrences(of: " ", with: "").count {
                return true
            }
        }
        return false
    }

    private static func bulletItemText(_ trimmed: String) -> String? {
        for marker in ["- ", "* ", "+ "] {
            if trimmed.hasPrefix(marker) {
                return String(trimmed.dropFirst(marker.count))
            }
        }
        return nil
    }

    private static func numberedItemText(_ trimmed: String) -> String? {
        numberedItem(trimmed)?.text
    }

    private static func numberedItem(_ trimmed: String) -> (number: Int, text: String)? {
        guard let dotIndex = trimmed.firstIndex(of: ".") else { return nil }
        let prefix = trimmed[trimmed.startIndex..<dotIndex]
        guard !prefix.isEmpty, prefix.allSatisfy({ $0.isNumber }), let number = Int(prefix) else {
            return nil
        }
        let afterDot = trimmed[trimmed.index(after: dotIndex)...]
        guard afterDot.hasPrefix(" ") else { return nil }
        return (number, String(afterDot.dropFirst()))
    }

    private enum ListKind {
        case bullet
        case numbered

        var other: ListKind { self == .bullet ? .numbered : .bullet }
    }

    /// The list starting at `index`, or nil if the line there is not an item
    /// of that kind.
    ///
    /// Two things beyond consecutive item lines belong to the list, and both
    /// are ordinary agent output: a blank line between items, and a wrapped
    /// item whose continuation sits on the next line. Ending the list at
    /// either gave every item a block of its own, which the numbered marker —
    /// positional within its block — rendered as a row of `1.`.
    private static func list(
        startingAt index: Int,
        in lines: [String],
        kind: ListKind
    ) -> (items: [String], start: Int, end: Int)? {
        guard let first = item(lines[index], kind: kind) else { return nil }
        var items = [first.text]
        var cursor = index + 1
        var end = cursor
        var followsBlankLine = false

        while cursor < lines.count {
            let trimmed = lines[cursor].trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                followsBlankLine = true
                cursor += 1
                continue
            }
            if beginsOtherBlock(at: cursor, in: lines) { break }
            if let next = item(lines[cursor], kind: kind) {
                items.append(next.text)
                cursor += 1
                end = cursor
                followsBlankLine = false
                continue
            }
            // A blank line closed the last item, so this line starts something
            // new rather than continuing it.
            if followsBlankLine || item(lines[cursor], kind: kind.other) != nil { break }
            items[items.count - 1] += " " + trimmed
            cursor += 1
            end = cursor
        }

        return (items, first.number ?? 1, end)
    }

    private static func item(_ line: String, kind: ListKind) -> (number: Int?, text: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        switch kind {
        case .bullet:
            return bulletItemText(trimmed).map { (nil, $0) }
        case .numbered:
            return numberedItem(trimmed).map { ($0.number, $0.text) }
        }
    }

    /// Whether the line starts a block that no list item can continue into.
    private static func beginsOtherBlock(at cursor: Int, in lines: [String]) -> Bool {
        let trimmed = lines[cursor].trimmingCharacters(in: .whitespaces)
        return fenceMarker(trimmed) != nil
            || headingLevel(trimmed) != nil
            || tableAt(cursor, in: lines) != nil
            || isRule(trimmed)
            || trimmed.hasPrefix(">")
    }
}
