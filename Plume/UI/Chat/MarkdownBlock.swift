import Foundation

/// A single block-level element of parsed markdown.
///
/// `AttributedString(markdown:)` handles inline formatting (bold, italic,
/// inline code, links) but has no notion of block structure — headings,
/// fenced code, lists, quotes. `parse(_:)` splits the raw text into blocks
/// by hand; `MarkdownView` then inline-parses each paragraph and list item.
///
nonisolated enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    /// A whole list, nesting included. Its items are flat and each carries its
    /// own depth and marker, so the list can be cut anywhere without losing
    /// either — which is what `ChatPieceSplitter` does to a long one.
    case list([ListItem])
    case codeBlock(language: String?, code: String)
    /// `continues` is set on every piece of a quote the splitter broke up, so
    /// the bar is drawn through the gap above it and the split reads as one
    /// quote. False for a quote that was never split, and for its first piece.
    case quote(String, continues: Bool = false)
    case table(header: [String], alignments: [ColumnAlignment], rows: [[String]])
    case rule

    /// One item of a list, at whatever depth the source indented it to.
    ///
    /// `number` is nil for a bullet and the item's own rendered number
    /// otherwise, resolved at parse time rather than from a position within
    /// the list. A segment of a split list therefore numbers itself from what
    /// its items already carry, and a sublist restarting at 1 inside an outer
    /// list that is at 7 needs no extra state to say so.
    nonisolated struct ListItem: Equatable {
        var text: String
        /// Nesting level, 0 for the outermost items.
        var depth: Int = 0
        var number: Int?

        var isNumbered: Bool { number != nil }
    }

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
        case .list: "list"
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
    /// A piece holding a whole block copies these lines rather than a
    /// markdown rendering written back from the block.
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

            if let list = list(startingAt: index, in: lines) {
                append(.list(list.items), from: index, to: list.end)
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

    /// One source line that opens a list item, before depths are assigned.
    private struct RawItem {
        /// Leading whitespace columns, which decide the item's depth.
        let indent: Int
        /// The number the source wrote, or nil for a bullet.
        let sourceNumber: Int?
        var text: String
    }

    /// The list starting at `index`, or nil if the line there is not a list
    /// item.
    ///
    /// Two things beyond consecutive item lines belong to the list, and both
    /// are ordinary agent output: a blank line between items, and a wrapped
    /// item whose continuation sits on the next line. Ending the list at
    /// either gave every item a block of its own, which the numbered marker —
    /// positional within its block — rendered as a row of `1.`.
    ///
    /// A change of marker no longer ends the list: an indented sublist is
    /// routinely a different kind from the list holding it, and each item
    /// carries its own marker anyway.
    private static func list(
        startingAt index: Int,
        in lines: [String]
    ) -> (items: [ListItem], end: Int)? {
        guard let first = rawItem(lines[index]) else { return nil }
        var raw = [first]
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
            if let next = rawItem(lines[cursor]) {
                raw.append(next)
                cursor += 1
                end = cursor
                followsBlankLine = false
                continue
            }
            // A blank line closed the last item, so this line starts something
            // new rather than continuing it.
            if followsBlankLine { break }
            raw[raw.count - 1].text += " " + trimmed
            cursor += 1
            end = cursor
        }

        return (resolvingDepths(raw), end)
    }

    /// Turns each item's indent into a depth, and each source marker into the
    /// number that item renders with.
    ///
    /// Depth comes from a stack of the indents seen so far rather than from
    /// dividing by a fixed width, because two and four space sublists are both
    /// ordinary and a source mixes them. An indent deeper than the current
    /// level opens one level, never several; an indent that matches no open
    /// level closes back to the nearest one at or above it.
    ///
    /// Numbering runs per depth: a numbered run counts up from the number its
    /// first item carried, and a sublist returning to its parent resumes the
    /// parent's count rather than restarting.
    private static func resolvingDepths(_ raw: [RawItem]) -> [ListItem] {
        var indents: [Int] = []
        // The number the next numbered item at each depth renders with, or nil
        // where no numbered run is open there.
        var counters: [Int?] = []
        var items: [ListItem] = []

        for entry in raw {
            let depth: Int
            if let match = indents.lastIndex(where: { $0 <= entry.indent }) {
                // Deeper than every open level opens exactly one more.
                depth = indents[match] < entry.indent ? match + 1 : match
            } else {
                depth = 0
            }
            indents = Array(indents.prefix(depth)) + [entry.indent]
            // Every level this item closed loses its count, so a sublist
            // reopening later starts from its own source number again.
            counters = Array(counters.prefix(depth + 1))
            while counters.count <= depth { counters.append(nil) }

            var number: Int?
            if let source = entry.sourceNumber {
                // An open run ignores the source's number, so a list that
                // repeats `1.` still renders 1, 2, 3. A run that has just
                // opened takes it, so one beginning at 3 counts from 3.
                number = counters[depth] ?? source
                counters[depth] = number! + 1
            } else {
                counters[depth] = nil
            }
            items.append(ListItem(text: entry.text, depth: depth, number: number))
        }
        return items
    }

    private static func rawItem(_ line: String) -> RawItem? {
        let indent = line.prefix { $0 == " " || $0 == "\t" }
            .reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if let text = bulletItemText(trimmed) {
            return RawItem(indent: indent, sourceNumber: nil, text: text)
        }
        if let numbered = numberedItem(trimmed) {
            return RawItem(indent: indent, sourceNumber: numbered.number, text: numbered.text)
        }
        return nil
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
