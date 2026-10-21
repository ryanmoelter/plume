import AppKit
import Foundation

/// Turns a selection into text for the pasteboard, from the pieces alone.
///
/// A piece the selection covers whole yields its `copySource`. A piece it cuts
/// is written back from the inline parse, so partial bold, links and code
/// keep their markup. Pieces that are not markdown are skipped.
enum ChatSelectionSerializer {
    struct Slice {
        let piece: ChatPiece
        let text: ChatSelectableText
        let range: Range<Int>
        let isWhole: Bool
    }

    /// The selected part of each piece, in list order.
    static func slices(of pieces: [ChatPiece], selection: ChatSelection) -> [Slice] {
        let order = ChatPieceOrder(pieces.map(\.id))
        guard let bounds = selection.bounds(in: order),
              let first = order.index(of: bounds.start.pieceID),
              let last = order.index(of: bounds.end.pieceID) else { return [] }
        return (first...last).compactMap { index in
            let piece = pieces[index]
            guard MarkdownSource.markdown(of: piece.content) != nil else { return nil }
            let text = ChatSelectableText(piece: piece)
            let length = text.length
            let lower = index == first ? min(max(bounds.start.offset, 0), length) : 0
            let upper = index == last ? min(max(bounds.end.offset, 0), length) : length
            let isInterior = index != first && index != last
            guard lower < upper || (isInterior && length == 0) else { return nil }
            return Slice(piece: piece, text: text, range: lower..<upper, isWhole: lower == 0 && upper == length)
        }
    }

    static func markdown(of pieces: [ChatPiece], selection: ChatSelection) -> String {
        let blocks: [(piece: ChatPiece, text: String)] = slices(of: pieces, selection: selection).compactMap { slice in
            let markdown = slice.isWhole
                ? slice.piece.copySource ?? MarkdownSource.markdown(of: slice.piece.content)
                : partialMarkdown(of: slice)
            guard let markdown, !markdown.isEmpty else { return nil }
            return (slice.piece, markdown)
        }
        return join(blocks)
    }

    static func plainText(of pieces: [ChatPiece], selection: ChatSelection) -> String {
        String(attributed(of: pieces, selection: selection).characters)
    }

    /// RTF with font traits and links, and no colors, so a paste takes the
    /// destination's own.
    static func rtf(of pieces: [ChatPiece], selection: ChatSelection) -> Data? {
        let rendered = attributed(of: pieces, selection: selection)
        guard !rendered.characters.isEmpty else { return nil }
        let output = NSMutableAttributedString()
        for run in rendered.runs {
            let intent = run.inlinePresentationIntent ?? []
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font(
                    bold: intent.contains(.stronglyEmphasized) || run.isHeading,
                    italic: intent.contains(.emphasized),
                    mono: intent.contains(.code) || run.isCode
                )
            ]
            if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = run.link { attributes[.link] = link }
            output.append(NSAttributedString(string: String(rendered[run.range].characters), attributes: attributes))
        }
        return try? output.data(
            from: NSRange(location: 0, length: output.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
    }

    // MARK: - Joining

    private static func join(_ blocks: [(piece: ChatPiece, text: String)]) -> String {
        var result = ""
        for (index, block) in blocks.enumerated() {
            if index > 0 { result += separator(between: blocks[index - 1].piece, and: block.piece) }
            result += block.text
        }
        return result
    }

    private static func separator(between previous: ChatPiece, and next: ChatPiece) -> String {
        previous.continuesList(in: next) ? "\n" : "\n\n"
    }

    // MARK: - Fragments in range

    private struct Selected {
        let fragment: ChatSelectableText.Fragment
        let local: Range<Int>

        var includesStart: Bool { local.lowerBound == 0 }
        var source: AttributedString { fragment.source.slice(utf16: local) }
    }

    private static func selected(in slice: Slice) -> [Selected] {
        let fragments = slice.text.fragments
        let hits = fragments.indices.filter { index in
            let fragment = fragments[index]
            return fragment.start < slice.range.upperBound && fragment.end > slice.range.lowerBound
        }
        guard let first = hits.first, let last = hits.last else { return [] }
        let isTable = fragments[first].kind.isTableCell
        // A table's empty cells between selected ones still mark their column.
        let indices = isTable ? Array(first...last) : hits
        return indices.map { index in
            let fragment = fragments[index]
            let lower = max(slice.range.lowerBound, fragment.start) - fragment.start
            let upper = min(slice.range.upperBound, fragment.end) - fragment.start
            return Selected(fragment: fragment, local: lower..<max(lower, upper))
        }
    }

    // MARK: - Markdown

    private static func partialMarkdown(of slice: Slice) -> String? {
        let parts = selected(in: slice)
        guard !parts.isEmpty else { return nil }
        if parts[0].fragment.kind.isTableCell { return tableMarkdown(parts, piece: slice.piece) }
        return parts.map(fragmentMarkdown).joined(separator: "\n")
    }

    private static func fragmentMarkdown(_ part: Selected) -> String {
        let source = part.source
        switch part.fragment.kind {
        case .paragraph, .tableCell:
            return inlineMarkdown(source)
        case let .heading(level):
            return (part.includesStart ? String(repeating: "#", count: level) + " " : "") + inlineMarkdown(source)
        case let .listItem(depth, _, ordinal):
            let prefix = String(repeating: "  ", count: depth) + (ordinal.map { "\($0). " } ?? "- ")
            return (part.includesStart ? prefix : "") + inlineMarkdown(source)
        case .quote:
            let lines = inlineMarkdown(source).components(separatedBy: "\n")
            return lines.enumerated().map { index, line in
                if index == 0, !part.includesStart { return line }
                return line.isEmpty ? ">" : "> " + line
            }
            .joined(separator: "\n")
        case let .code(language, _):
            return MarkdownSource.markdown(of: CodeSegment(language: language, code: String(source.characters)))
        }
    }

    private static func tableMarkdown(_ parts: [Selected], piece: ChatPiece) -> String {
        guard case let .markdown(.table(header, alignments, _), _) = piece.content else { return "" }
        let cells = ChatSelectableText(piece: piece).fragments.compactMap { fragment -> (row: Int, column: Int, text: String)? in
            guard case let .tableCell(row, column, _) = fragment.kind else { return nil }
            return (row, column, inlineMarkdown(fragment.source)
                .replacingOccurrences(of: #"(?<!\\)\|"#, with: #"\\|"#, options: .regularExpression))
        }
        let touchedRows = Set(parts.compactMap { part -> Int? in
            if case let .tableCell(row, _, _) = part.fragment.kind { row } else { nil }
        })
        let columnCount = (cells.map(\.column).max() ?? -1) + 1
        let hasHeader = MarkdownBlock.headerIsMeaningful(header)

        func line(_ texts: [String]) -> String { "| " + texts.joined(separator: " | ") + " |" }
        func row(_ index: Int) -> String {
            line((0..<columnCount).map { column in cells.first { $0.row == index && $0.column == column }?.text ?? "" })
        }

        let delimiters = (0..<columnCount).map { column -> String in
            switch alignments.indices.contains(column) ? alignments[column] : .leading {
            case .leading: "---"
            case .center: ":-:"
            case .trailing: "--:"
            }
        }
        let headerLine = hasHeader ? row(0) : line(Array(repeating: "", count: columnCount))
        let bodyRows = touchedRows.sorted().filter { !(hasHeader && $0 == 0) }
        return ([headerLine, line(delimiters)] + bodyRows.map(row)).joined(separator: "\n")
    }

    /// Writes runs back as inline markdown. Delimiters hug the text, so
    /// whitespace at a run's edges stays outside them.
    static func inlineMarkdown(_ text: AttributedString) -> String {
        var atLineStart = true
        return text.runs.map { run -> String in
            let content = String(text[run.range].characters)
            let intent = run.inlinePresentationIntent ?? []
            let core = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !core.isEmpty else {
                if content.contains("\n") { atLineStart = content.hasSuffix("\n") }
                return content
            }
            let leading = String(content.prefix { $0.isWhitespace })
            let trailing = String(content.reversed().prefix { $0.isWhitespace }.reversed())
            let startsLine = atLineStart || leading.contains("\n")
            atLineStart = trailing.contains("\n")

            var marked: String
            if intent.contains(.code) {
                marked = codeSpan(core)
            } else {
                marked = escape(core, atLineStart: startsLine)
                if intent.contains(.strikethrough) { marked = "~~\(marked)~~" }
                if intent.contains(.emphasized) { marked = "*\(marked)*" }
                if intent.contains(.stronglyEmphasized) { marked = "**\(marked)**" }
            }
            if let link = run.link { marked = "[\(marked)](\(destination(link)))" }
            return leading + marked + trailing
        }
        .joined()
    }

    private static func codeSpan(_ code: String) -> String {
        var longest = 0
        var current = 0
        for character in code {
            current = character == "`" ? current + 1 : 0
            longest = max(longest, current)
        }
        let fence = String(repeating: "`", count: longest + 1)
        let padded = longest > 0 && (code.hasPrefix("`") || code.hasSuffix("`")) ? " \(code) " : code
        return fence + padded + fence
    }

    private static func destination(_ link: URL) -> String {
        let string = link.absoluteString
        return string.contains { " ()".contains($0) } ? "<\(string)>" : string
    }

    private static func escape(_ text: String, atLineStart: Bool) -> String {
        let lines = text.components(separatedBy: "\n")
        return lines.enumerated().map { index, line in
            let escaped = line.map { "\\*_`[]~<|".contains($0) ? "\\\($0)" : String($0) }.joined()
            return index > 0 || atLineStart ? escapingBlockMarker(escaped) : escaped
        }
        .joined(separator: "\n")
    }

    /// Escapes a leading character that would turn the line into a block.
    private static func escapingBlockMarker(_ line: String) -> String {
        let indent = line.prefix { $0 == " " }
        let rest = line.dropFirst(indent.count)
        if let first = rest.first, "#>-+".contains(first) { return indent + "\\" + rest }
        let digits = rest.prefix { $0.isASCII && $0.isNumber }
        let afterDigits = rest.dropFirst(digits.count)
        if !digits.isEmpty, let mark = afterDigits.first, ".)".contains(mark),
           afterDigits.dropFirst().first.map({ $0 == " " }) ?? true {
            return indent + digits + "\\" + afterDigits
        }
        return line
    }

    // MARK: - Plain text and RTF

    /// The rendered text of the selection, tagged so `rtf` can style it:
    /// `.inlinePresentationIntent` carries bold, italic and code, and the
    /// heading and code fragments get theirs from the fragment kind.
    private static func attributed(of pieces: [ChatPiece], selection: ChatSelection) -> AttributedString {
        var result = AttributedString()
        var previous: ChatPiece?
        for slice in slices(of: pieces, selection: selection) {
            let rendered = renderedText(of: slice)
            guard !rendered.characters.isEmpty else { continue }
            if let previous, !result.characters.isEmpty {
                result += AttributedString(separator(between: previous, and: slice.piece))
            }
            result += rendered
            previous = slice.piece
        }
        return result
    }

    private static func renderedText(of slice: Slice) -> AttributedString {
        let parts = selected(in: slice)
        var result = AttributedString()
        var previous: Selected?
        for part in parts {
            if let previous {
                result += AttributedString(separator(from: previous, to: part))
            }
            result += renderedText(of: part)
            previous = part
        }
        return result
    }

    private static func separator(from previous: Selected, to part: Selected) -> String {
        guard case let .tableCell(previousRow, _, _) = previous.fragment.kind,
              case let .tableCell(row, _, _) = part.fragment.kind else { return "\n" }
        return previousRow == row ? "\t" : "\n"
    }

    /// Heading levels 5 and 6 draw uppercased but copy in the source's case.
    private static func renderedText(of part: Selected) -> AttributedString {
        var text = part.source
        switch part.fragment.kind {
        case .heading:
            text.isHeading = true
        case let .listItem(_, marker, _):
            if part.includesStart { text = AttributedString(marker + " ") + text }
        case .code:
            text.isCode = true
        case .paragraph, .quote, .tableCell:
            break
        }
        return text
    }

    private static func font(bold: Bool, italic: Bool, mono: Bool) -> NSFont {
        let weight: NSFont.Weight = bold ? .bold : .regular
        let base = mono
            ? NSFont.monospacedSystemFont(ofSize: 13, weight: weight)
            : NSFont.systemFont(ofSize: 13, weight: weight)
        return italic ? NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask) : base
    }
}

private enum SelectionStyleKey: AttributedStringKey {
    typealias Value = Bool
    static let name = "plume.selection.heading"
}

private enum SelectionCodeKey: AttributedStringKey {
    typealias Value = Bool
    static let name = "plume.selection.code"
}

private extension AttributedString {
    var isHeading: Bool {
        get { runs.first?[SelectionStyleKey.self] ?? false }
        set { self[startIndex..<endIndex][SelectionStyleKey.self] = newValue }
    }

    var isCode: Bool {
        get { runs.first?[SelectionCodeKey.self] ?? false }
        set { self[startIndex..<endIndex][SelectionCodeKey.self] = newValue }
    }
}

private extension AttributedString.Runs.Run {
    var isHeading: Bool { self[SelectionStyleKey.self] ?? false }
    var isCode: Bool { self[SelectionCodeKey.self] ?? false }
}

private extension ChatSelectableText.Fragment.Kind {
    var isTableCell: Bool {
        if case .tableCell = self { true } else { false }
    }
}

private extension ChatPiece {
    func continuesList(in next: ChatPiece) -> Bool {
        guard case let .listSegment(first) = content, case let .listSegment(second) = next.content,
              messageID == next.messageID, !first.position.isLast, !second.position.isFirst,
              let last = first.items.last, let following = second.items.first else { return false }
        let changesKind = last.depth == following.depth && last.isNumbered != following.isNumbered
        return !changesKind && id.split(separator: "/").dropLast() == next.id.split(separator: "/").dropLast()
    }
}
