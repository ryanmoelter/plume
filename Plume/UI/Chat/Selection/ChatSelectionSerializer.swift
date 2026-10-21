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
        let blocks: [(isList: Bool, markdown: String)] = slices(of: pieces, selection: selection).compactMap { slice in
            let markdown = slice.isWhole
                ? slice.piece.copySource ?? MarkdownSource.markdown(of: slice.piece.content)
                : partialMarkdown(of: slice)
            guard let markdown, !markdown.isEmpty else { return nil }
            return (slice.piece.isList, markdown)
        }
        return join(blocks.map { ($0.isList, $0.markdown) })
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

    private static func join(_ blocks: [(isList: Bool, text: String)]) -> String {
        var result = ""
        var previousIsList = false
        for (index, block) in blocks.enumerated() {
            if index > 0 { result += previousIsList && block.isList ? "\n" : "\n\n" }
            result += block.text
            previousIsList = block.isList
        }
        return result
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
        var alignments: [MarkdownBlock.ColumnAlignment] = []
        if case let .markdown(.table(_, columnAlignments, _), _) = piece.content { alignments = columnAlignments }
        var lines: [String] = []
        var cells: [String] = []
        var columns: [Int] = []
        var currentRow: Int?
        var currentIsHeader = false

        func flush() {
            guard !cells.isEmpty else { return }
            lines.append("| " + cells.joined(separator: " | ") + " |")
            if currentIsHeader {
                let delimiters = columns.map { column -> String in
                    switch alignments.indices.contains(column) ? alignments[column] : .leading {
                    case .leading: "---"
                    case .center: ":-:"
                    case .trailing: "--:"
                    }
                }
                lines.append("| " + delimiters.joined(separator: " | ") + " |")
            }
            cells = []
            columns = []
        }

        for part in parts {
            guard case let .tableCell(row, column, isHeader) = part.fragment.kind else { continue }
            if row != currentRow {
                flush()
                currentRow = row
                currentIsHeader = isHeader
            }
            cells.append(inlineMarkdown(part.source).replacingOccurrences(of: "|", with: "\\|"))
            columns.append(column)
        }
        flush()
        return lines.joined(separator: "\n")
    }

    /// Writes runs back as inline markdown. Delimiters hug the text, so
    /// whitespace at a run's edges stays outside them.
    static func inlineMarkdown(_ text: AttributedString) -> String {
        text.runs.map { run -> String in
            let content = String(text[run.range].characters)
            let intent = run.inlinePresentationIntent ?? []
            let core = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !core.isEmpty else { return content }
            let leading = String(content.prefix { $0.isWhitespace })
            let trailing = String(content.reversed().prefix { $0.isWhitespace }.reversed())

            var marked: String
            if intent.contains(.code) {
                marked = codeSpan(core)
            } else {
                marked = escape(core)
                if intent.contains(.strikethrough) { marked = "~~\(marked)~~" }
                if intent.contains(.emphasized) { marked = "*\(marked)*" }
                if intent.contains(.stronglyEmphasized) { marked = "**\(marked)**" }
            }
            if let link = run.link { marked = "[\(marked)](\(link.absoluteString))" }
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

    private static func escape(_ text: String) -> String {
        var result = ""
        for character in text {
            if "\\*_`[]".contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }

    // MARK: - Plain text and RTF

    /// The rendered text of the selection, tagged so `rtf` can style it:
    /// `.inlinePresentationIntent` carries bold, italic and code, and the
    /// heading and code fragments get theirs from the fragment kind.
    private static func attributed(of pieces: [ChatPiece], selection: ChatSelection) -> AttributedString {
        var result = AttributedString()
        var previousIsList = false
        for slice in slices(of: pieces, selection: selection) {
            let rendered = renderedText(of: slice)
            guard !rendered.characters.isEmpty else { continue }
            if !result.characters.isEmpty {
                result += AttributedString(previousIsList && slice.piece.isList ? "\n" : "\n\n")
            }
            result += rendered
            previousIsList = slice.piece.isList
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

    /// Heading levels 5 and 6 draw uppercased, but offsets come from the
    /// source as `ChatReveal.length` counts it, so the slice is cut first and
    /// uppercased after.
    private static func renderedText(of part: Selected) -> AttributedString {
        var text = part.source
        switch part.fragment.kind {
        case let .heading(level):
            if level >= 5 { text = uppercased(text) }
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

    private static func uppercased(_ text: AttributedString) -> AttributedString {
        text.runs.reduce(into: AttributedString()) { result, run in
            var raised = AttributedString(String(text[run.range].characters).uppercased())
            raised.mergeAttributes(run.attributes)
            result += raised
        }
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
    var isList: Bool {
        switch content {
        case .listSegment, .markdown(.list, _): true
        default: false
        }
    }
}
