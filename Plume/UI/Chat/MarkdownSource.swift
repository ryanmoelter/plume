import Foundation

/// Renders a parsed block back into markdown, for the pieces whose own source
/// the splitter could not keep.
///
/// A block the splitter left whole carries the exact lines it was parsed from,
/// so copying yields the agent's own text. A block it split does not: a
/// paragraph's segment and a list's single item are slices the parse never
/// named, so their markdown is written back from the structure instead. That
/// round trip normalizes whitespace and list markers, which is why it is the
/// fallback rather than the rule.
enum MarkdownSource {
    /// Nil for a piece that is not markdown — a tool call, a notice, an image.
    static func markdown(of content: ChatPiece.Content) -> String? {
        switch content {
        case let .markdown(block, _): markdown(of: block)
        case let .codeSegment(segment): markdown(of: segment)
        case let .listSegment(segment): markdown(of: segment)
        case .thinking, .toolCall, .injected, .notice, .image, .streaming, .working: nil
        }
    }

    static func markdown(of block: MarkdownBlock) -> String {
        switch block {
        case let .heading(level, text):
            String(repeating: "#", count: level) + " " + text
        case let .paragraph(text):
            text
        case let .bulletList(items):
            markdown(of: ListSegment(kind: .bullet, items: items))
        case let .numberedList(items, start):
            markdown(of: ListSegment(kind: .numbered, items: items, startNumber: start))
        case let .codeBlock(language, code):
            markdown(of: CodeSegment(language: language, code: code))
        case let .quote(text, _):
            text.components(separatedBy: "\n")
                .map { $0.isEmpty ? ">" : "> " + $0 }
                .joined(separator: "\n")
        case let .table(header, alignments, rows):
            table(header: header, alignments: alignments, rows: rows)
        case .rule:
            "---"
        }
    }

    static func markdown(of segment: CodeSegment) -> String {
        let fence = fence(for: segment.code)
        return "\(fence)\(segment.language ?? "")\n\(segment.code)\n\(fence)"
    }

    static func markdown(of segment: ListSegment) -> String {
        segment.items.enumerated().map { index, item in
            switch segment.kind {
            case .bullet: "- " + item
            case .numbered: "\(segment.startNumber + index). " + item
            }
        }
        .joined(separator: "\n")
    }

    /// A fence long enough to survive code that contains a fence of its own.
    private static func fence(for code: String) -> String {
        let longest = code.components(separatedBy: "\n")
            .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
            .map { $0.trimmingCharacters(in: .whitespaces).prefix { $0 == "`" }.count }
            .max() ?? 0
        return String(repeating: "`", count: max(3, longest + 1))
    }

    private static func table(
        header: [String],
        alignments: [MarkdownBlock.ColumnAlignment],
        rows: [[String]]
    ) -> String {
        let columnCount = max(header.count, alignments.count, rows.map(\.count).max() ?? 0)
        func line(_ cells: [String]) -> String {
            let padded = (0..<columnCount).map { cells.indices.contains($0) ? escape(cells[$0]) : "" }
            return "| " + padded.joined(separator: " | ") + " |"
        }
        let delimiters = (0..<columnCount).map { column -> String in
            switch alignments.indices.contains(column) ? alignments[column] : .leading {
            case .leading: "---"
            case .center: ":-:"
            case .trailing: "--:"
            }
        }
        return ([line(header), line(delimiters)] + rows.map(line)).joined(separator: "\n")
    }

    /// A cell's own pipe has to stay a cell's content, not a column break.
    private static func escape(_ cell: String) -> String {
        cell.replacingOccurrences(of: "|", with: "\\|")
    }
}
