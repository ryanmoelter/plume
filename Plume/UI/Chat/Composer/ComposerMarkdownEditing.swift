import Foundation

/// The composer's markdown-aware keys, as pure text transforms: text and
/// selection in, the edited text and selection out. Nil means the key keeps
/// its ordinary `NSTextView` behavior.
///
/// | Key | Where | Result |
/// | --- | --- | --- |
/// | Return | non-empty list item | a new item at the same indent, the next number for an ordered list |
/// | Return | empty list item | one level out, or out of the list at the top level |
/// | Return | quote line | continues the quote; an empty one leaves a level |
/// | Tab | start of a list item | indents under the item above, to its text column |
/// | Shift-Tab | list item | outdents to the parent's indent |
/// | Delete | start of a list item's text | removes the marker, or outdents a nested item |
/// | Delete | start of a quote line's text | removes one quote level |
/// | Delete | start of the line after a rule | removes the rule's last character |
///
/// Code and fence lines are left alone. Every list edit renumbers the
/// ordered lists it touches.
nonisolated enum ComposerMarkdownEditing {
    struct Result: Equatable {
        var text: String
        var selection: NSRange
    }

    // MARK: - Return

    static func newline(in text: String, selection: NSRange) -> Result? {
        guard selection.length == 0 else { return nil }
        let ns = text as NSString
        let lines = MarkdownLineStructure.lines(in: text)
        guard let index = lineIndex(containing: selection.location, in: lines) else { return nil }
        let line = lines[index]
        let caret = selection.location
        guard caret >= line.contentStart else { return nil }
        let isEmpty = line.contentStart == NSMaxRange(line.range)

        if line.isListItem {
            if isEmpty {
                if line.depth > 0 {
                    return outdent(in: text, selection: selection)
                }
                let removed = NSRange(location: line.indent.location, length: line.contentStart - line.indent.location)
                return edit(text, replacing: removed, with: "", caret: removed.location, renumbering: [index, index + 1])
            }
            let continuation = "\n" + quotePrefix(of: line, in: ns) + ns.substring(with: line.indent) + nextMarker(after: line, in: ns)
            let caretAfter = caret + (continuation as NSString).length
            return edit(text, replacing: NSRange(location: caret, length: 0), with: continuation, caret: caretAfter, renumbering: [index + 1])
        }

        if line.quoteLevel > 0, line.kind == .plain || line.kind == .blank {
            if isEmpty, let last = line.quoteMarkers.last {
                return edit(text, replacing: last, with: "", caret: last.location)
            }
            let continuation = "\n" + quotePrefix(of: line, in: ns)
            return edit(text, replacing: NSRange(location: caret, length: 0), with: continuation, caret: caret + (continuation as NSString).length)
        }
        return nil
    }

    // MARK: - Tab and Shift-Tab

    /// Indents a list item under the item above it at the same depth, to that
    /// item's text column, along with the lines nested under it. Returns the
    /// text unchanged when there is no such item, so Tab never inserts a tab
    /// character inside a list.
    static func indent(in text: String, selection: NSRange) -> Result? {
        let ns = text as NSString
        let lines = MarkdownLineStructure.lines(in: text)
        guard let index = lineIndex(containing: selection.location, in: lines) else { return nil }
        let line = lines[index]
        guard line.isListItem, selection.length > 0 || selection.location == line.contentStart else { return nil }
        guard let sibling = previousItem(before: index, in: lines, depth: line.depth, quoteLevel: line.quoteLevel) else {
            return Result(text: text, selection: selection)
        }
        let target = columns(of: sibling.indent, in: ns) + markerWidth(of: sibling)
        let delta = target - columns(of: line.indent, in: ns)
        return shift(index, by: delta, in: text, lines: lines, selection: selection)
    }

    static func outdent(in text: String, selection: NSRange) -> Result? {
        let ns = text as NSString
        let lines = MarkdownLineStructure.lines(in: text)
        guard let index = lineIndex(containing: selection.location, in: lines) else { return nil }
        let line = lines[index]
        guard line.isListItem else { return nil }
        let current = columns(of: line.indent, in: ns)
        guard current > 0 else { return Result(text: text, selection: selection) }
        let target = line.depth > 0
            ? previousItem(before: index, in: lines, depth: line.depth - 1, quoteLevel: line.quoteLevel)
                .map { columns(of: $0.indent, in: ns) } ?? 0
            : 0
        return shift(index, by: target - current, in: text, lines: lines, selection: selection)
    }

    /// Moves the item at `index` and every line nested under it by `delta`
    /// columns, keeping the caret on the same character.
    private static func shift(_ index: Int, by delta: Int, in text: String, lines: [MarkdownLine], selection: NSRange) -> Result {
        guard delta != 0 else { return Result(text: text, selection: selection) }
        let ns = text as NSString
        let line = lines[index]
        let base = columns(of: line.indent, in: ns)
        var affected = [index]
        for next in (index + 1)..<lines.count {
            let candidate = lines[next]
            guard candidate.quoteLevel == line.quoteLevel, candidate.kind != .blank,
                  columns(of: candidate.indent, in: ns) > base
            else { break }
            affected.append(next)
        }

        let result = NSMutableString(string: text)
        var selection = selection
        for lineIndex in affected.reversed() {
            let indent = lines[lineIndex].indent
            let newColumns = max(0, columns(of: indent, in: ns) + delta)
            let replacement = String(repeating: " ", count: newColumns)
            let change = (replacement as NSString).length - indent.length
            result.replaceCharacters(in: indent, with: replacement)
            selection = adjusted(selection, forChangeAt: indent, delta: change)
        }
        let shifted = result as String
        // An item indented into a new sublist heads it, so it counts from 1.
        let renumberedText = renumbered(
            shifted,
            around: [index, index + 1, affected.last.map { $0 + 1 } ?? index],
            restarting: delta > 0 ? index : nil
        )
        if selection.length == 0, (renumberedText as NSString).length != (shifted as NSString).length {
            selection.location = caretAfterRenumbering(selection.location, from: shifted, to: renumberedText)
        }
        return Result(text: renumberedText, selection: selection)
    }

    // MARK: - Delete

    static func deleteBackward(in text: String, selection: NSRange) -> Result? {
        guard selection.length == 0 else { return nil }
        let lines = MarkdownLineStructure.lines(in: text)
        guard let index = lineIndex(containing: selection.location, in: lines) else { return nil }
        let line = lines[index]
        let caret = selection.location

        if caret == line.contentStart, caret > line.range.location {
            if line.isListItem {
                if line.depth > 0 {
                    return outdent(in: text, selection: selection)
                }
                let removed = NSRange(location: line.indent.location, length: line.contentStart - line.indent.location)
                return edit(text, replacing: removed, with: "", caret: removed.location, renumbering: [index, index + 1])
            }
            if line.kind == .plain || line.kind == .blank, let last = line.quoteMarkers.last,
               line.contentStart == NSMaxRange(last) {
                return edit(text, replacing: last, with: "", caret: last.location)
            }
        }

        if caret == line.range.location, index > 0, lines[index - 1].kind == .rule {
            let rule = lines[index - 1].range
            let last = NSRange(location: NSMaxRange(rule) - 1, length: 1)
            return edit(text, replacing: last, with: "", caret: caret - 1)
        }
        return nil
    }

    // MARK: - Checkbox

    static func toggleCheckbox(_ box: NSRange, in text: String, selection: NSRange) -> Result? {
        let ns = text as NSString
        guard NSMaxRange(box) <= ns.length, box.length == 3 else { return nil }
        let mark = NSRange(location: box.location + 1, length: 1)
        let replacement = ns.substring(with: mark) == " " ? "x" : " "
        return Result(text: ns.replacingCharacters(in: mark, with: replacement), selection: selection)
    }

    // MARK: - Caret

    /// Keeps a caret out of a hidden prefix, so it moves over `- ` or `> `
    /// as one unit. Moving back from the item's text goes to the end of the
    /// line above; anything else that lands inside goes to the item's text.
    static func snappedSelection(_ proposed: NSRange, previous: NSRange?, in lines: [MarkdownLine]) -> NSRange {
        guard proposed.length == 0,
              let index = lineIndex(containing: proposed.location, in: lines),
              let prefix = lines[index].atomicPrefix,
              proposed.location >= prefix.location, proposed.location < NSMaxRange(prefix)
        else { return proposed }
        if let previous, previous.length == 0, previous.location == NSMaxRange(prefix), proposed.location < previous.location,
           prefix.location > 0 {
            return NSRange(location: prefix.location - 1, length: 0)
        }
        return NSRange(location: NSMaxRange(prefix), length: 0)
    }

    // MARK: - Renumbering

    /// Renumbers each ordered list that includes one of the lines at
    /// `indices`, counting up from its first item's number, or from 1 when
    /// that first item is `restarting`.
    static func renumbered(_ text: String, around indices: [Int], restarting: Int? = nil) -> String {
        let lines = MarkdownLineStructure.lines(in: text)
        var renumbered = Set<Int>()
        var replacements: [(NSRange, String)] = []

        for index in indices where lines.indices.contains(index) {
            guard case .ordered = lines[index].kind, !renumbered.contains(index) else { continue }
            let run = orderedRun(containing: index, in: lines)
            guard case let .ordered(first)? = run.first.map({ lines[$0].kind }) else { continue }
            let start = run.first == restarting ? 1 : first
            for (offset, member) in run.enumerated() {
                renumbered.insert(member)
                guard case let .ordered(number) = lines[member].kind, number != start + offset,
                      let marker = lines[member].marker
                else { continue }
                let digits = NSRange(location: marker.location, length: marker.length - 2)
                replacements.append((digits, String(start + offset)))
            }
        }
        guard !replacements.isEmpty else { return text }
        let result = NSMutableString(string: text)
        for (range, number) in replacements.sorted(by: { $0.0.location > $1.0.location }) {
            result.replaceCharacters(in: range, with: number)
        }
        return result as String
    }

    /// The ordered items at the same depth and quote level as `index`, in
    /// the list around it. Deeper items, their nested lines and blank lines
    /// sit inside a run; anything shallower or unindented ends it.
    private static func orderedRun(containing index: Int, in lines: [MarkdownLine]) -> [Int] {
        let anchor = lines[index]
        func membership(_ line: MarkdownLine) -> Bool? {
            guard line.quoteLevel == anchor.quoteLevel else { return nil }
            if line.isListItem {
                if line.depth > anchor.depth { return false }
                if line.depth == anchor.depth, case .ordered = line.kind { return true }
                return nil
            }
            if line.kind == .blank || line.indent.length > 0 && line.kind == .plain { return false }
            return nil
        }
        var start = index
        while start > 0, membership(lines[start - 1]) != nil {
            start -= 1
        }
        var end = index
        while end + 1 < lines.count, membership(lines[end + 1]) != nil {
            end += 1
        }
        return (start...end).filter { membership(lines[$0]) == true }
    }

    // MARK: - Helpers

    private static func lineIndex(containing location: Int, in lines: [MarkdownLine]) -> Int? {
        lines.lastIndex { $0.range.location <= location }
    }

    /// The nearest earlier item at `depth`, within the same list.
    private static func previousItem(before index: Int, in lines: [MarkdownLine], depth: Int, quoteLevel: Int) -> MarkdownLine? {
        var cursor = index - 1
        while cursor >= 0 {
            let line = lines[cursor]
            guard line.quoteLevel == quoteLevel else { return nil }
            if line.isListItem {
                if line.depth == depth { return line }
                if line.depth < depth { return nil }
            } else if line.kind != .blank, line.indent.length == 0 {
                return nil
            }
            cursor -= 1
        }
        return nil
    }

    private static func quotePrefix(of line: MarkdownLine, in ns: NSString) -> String {
        guard let last = line.quoteMarkers.last else { return "" }
        return ns.substring(with: NSRange(location: line.range.location, length: NSMaxRange(last) - line.range.location))
    }

    private static func nextMarker(after line: MarkdownLine, in ns: NSString) -> String {
        guard let marker = line.marker else { return "" }
        let bullet = ns.substring(with: NSRange(location: marker.location, length: 1))
        switch line.kind {
        case let .ordered(number):
            let delimiter = ns.substring(with: NSRange(location: NSMaxRange(marker) - 2, length: 1))
            return "\(number + 1)\(delimiter) "
        case .task:
            return "\(bullet) [ ] "
        default:
            return "\(bullet) "
        }
    }

    /// The columns a nested item's indent needs to sit under this item's
    /// text: the bullet and its space, or the number, delimiter and space.
    private static func markerWidth(of line: MarkdownLine) -> Int {
        guard case .ordered = line.kind, let marker = line.marker else { return 2 }
        return marker.length
    }

    private static func columns(of indent: NSRange, in ns: NSString) -> Int {
        var total = 0
        for offset in 0..<indent.length {
            total += ns.character(at: indent.location + offset) == 0x09 ? 4 : 1
        }
        return total
    }

    private static func adjusted(_ selection: NSRange, forChangeAt range: NSRange, delta: Int) -> NSRange {
        guard selection.location >= range.location else { return selection }
        let location = selection.location >= NSMaxRange(range)
            ? selection.location + delta
            : max(range.location, min(selection.location + delta, range.location + range.length + delta))
        return NSRange(location: max(0, location), length: selection.length)
    }

    private static func edit(_ text: String, replacing range: NSRange, with replacement: String, caret: Int, renumbering indices: [Int] = []) -> Result {
        let edited = (text as NSString).replacingCharacters(in: range, with: replacement)
        let result = indices.isEmpty ? edited : renumbered(edited, around: indices)
        // Renumbering can change a number's width before the caret.
        let shift = (result as NSString).length - (edited as NSString).length
        let caret = shift == 0 ? caret : caretAfterRenumbering(caret, from: edited, to: result)
        return Result(text: result, selection: NSRange(location: caret, length: 0))
    }

    /// Maps a caret across a renumbering by its distance from the end of its
    /// line, which renumbering never changes.
    private static func caretAfterRenumbering(_ caret: Int, from old: String, to new: String) -> Int {
        let oldNS = old as NSString
        let newNS = new as NSString
        let oldLine = oldNS.lineRange(for: NSRange(location: min(caret, oldNS.length), length: 0))
        let lineNumber = oldNS.substring(to: oldLine.location).count(where: { $0 == "\n" })
        var location = 0
        for _ in 0..<lineNumber {
            let range = newNS.lineRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(range)
        }
        let newLine = newNS.lineRange(for: NSRange(location: min(location, newNS.length), length: 0))
        let fromEnd = NSMaxRange(oldLine) - caret
        return max(newLine.location, NSMaxRange(newLine) - fromEnd)
    }
}
