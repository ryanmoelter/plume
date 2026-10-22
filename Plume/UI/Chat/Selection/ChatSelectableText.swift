import Foundation

/// The text a markdown piece draws, as the spans the reveal counts.
///
/// Offsets are piece-local: the message's reveal offset minus the piece's
/// `revealOffset`, counted in UTF-16 units exactly as `ChatReveal` counts them.
/// A list marker is a `Text` of its own that the reveal does not count, so it
/// never takes part in an offset.
struct ChatSelectableText: Equatable {
    struct Fragment: Equatable {
        enum Kind: Equatable {
            case paragraph
            case heading(level: Int)
            case listItem(depth: Int, marker: String, ordinal: Int?)
            case quote
            case tableCell(row: Int, column: Int, isHeader: Bool)
            case code(language: String?, code: String)
        }

        var start: Int
        var length: Int
        /// The inline parse of the source, without the view's font or tint.
        var source: AttributedString
        var kind: Kind

        var end: Int { start + length }
    }

    let fragments: [Fragment]

    init(piece: ChatPiece) {
        fragments = Self.fragments(of: piece)
    }

    var length: Int { fragments.last?.end ?? 0 }

    var plainText: String {
        fragments.map { String($0.source.characters) }.joined()
    }

    static func length(of piece: ChatPiece) -> Int {
        ChatReveal.length(of: piece.content)
    }

    /// The fragment holding `offset`. An offset on the boundary between two
    /// fragments belongs to the later one, and the end of the text to the last.
    func fragmentIndex(containing offset: Int) -> Int? {
        guard offset >= 0, offset <= length else { return nil }
        if let index = fragments.firstIndex(where: { $0.start <= offset && offset < $0.end }) { return index }
        return fragments.lastIndex { $0.length > 0 }
    }

    /// The word at `offset`, or the run of spaces and punctuation between two
    /// words when `offset` falls in one. Words never span fragments, so two
    /// list items or table cells stay apart.
    func wordRange(at offset: Int) -> Range<Int>? {
        guard let index = fragmentIndex(containing: offset) else { return nil }
        let fragment = fragments[index]
        let text = String(fragment.source.characters) as NSString
        let local = min(max(offset - fragment.start, 0), fragment.length)
        var found: Range<Int>?
        var previousEnd = 0
        var gap: Range<Int>?
        text.enumerateSubstrings(
            in: NSRange(location: 0, length: text.length),
            options: [.byWords, .substringNotRequired]
        ) { _, range, _, stop in
            if range.location <= local, local < range.location + range.length {
                found = range.location..<(range.location + range.length)
                stop.pointee = true
            } else if range.location > local {
                gap = previousEnd..<range.location
                stop.pointee = true
            }
            previousEnd = range.location + range.length
        }
        let result = found ?? gap ?? previousEnd..<text.length
        guard !result.isEmpty else { return nil }
        return (fragment.start + result.lowerBound)..<(fragment.start + result.upperBound)
    }

    static func fragments(of piece: ChatPiece) -> [Fragment] {
        switch piece.content {
        case let .markdown(block, _): fragments(of: block)
        case let .listSegment(segment): listFragments(segment.items)
        case let .codeSegment(segment): segment.isMermaid ? [] : [code(segment.language, segment.code)]
        case .thinking, .toolCall, .injected, .agentMessageTitle, .agentMessageToggle, .notice, .image,
             .working, .waitingOnSubagents: []
        }
    }

    private static func fragments(of block: MarkdownBlock) -> [Fragment] {
        switch block {
        case let .paragraph(text): [inline(text, at: 0, .paragraph)]
        case let .heading(level, text): [inline(text, at: 0, .heading(level: level))]
        case let .quote(text, _): [inline(text, at: 0, .quote)]
        case let .list(items): listFragments(items)
        case let .codeBlock(language, code):
            MermaidDocument.isMermaidFence(language: language) ? [] : [Self.code(language, code)]
        case let .table(header, _, rows): tableFragments(header: header, rows: rows)
        case .rule: []
        }
    }

    private static func inline(_ text: String, at start: Int, _ kind: Fragment.Kind) -> Fragment {
        Fragment(start: start, length: ChatReveal.length(of: text), source: MarkdownCache.inline(text), kind: kind)
    }

    private static func code(_ language: String?, _ code: String) -> Fragment {
        Fragment(
            start: 0,
            length: code.utf16.count,
            source: AttributedString(code),
            kind: .code(language: language, code: code)
        )
    }

    private static func listFragments(_ items: [MarkdownBlock.ListItem]) -> [Fragment] {
        var offset = 0
        return items.map { item in
            let fragment = inline(
                item.text,
                at: offset,
                .listItem(depth: item.depth, marker: marker(for: item), ordinal: item.number)
            )
            offset = fragment.end
            return fragment
        }
    }

    private static func tableFragments(header: [String], rows: [[String]]) -> [Fragment] {
        let columnCount = max(header.count, rows.map(\.count).max() ?? 0)
        let hasHeader = MarkdownBlock.headerIsMeaningful(header)
        var offset = 0
        return ChatReveal.tableCells(header: header, rows: rows).enumerated().map { index, cell in
            let row = index / columnCount
            let fragment = inline(
                cell,
                at: offset,
                .tableCell(row: row, column: index % columnCount, isHeader: hasHeader && row == 0)
            )
            offset = fragment.end
            return fragment
        }
    }

    /// The glyphs `ListSegmentView` draws.
    private static let bullets = ["\u{2022}", "\u{25E6}", "\u{25AA}"]

    private static func marker(for item: MarkdownBlock.ListItem) -> String {
        guard let number = item.number else { return bullets[item.depth % bullets.count] }
        return "\(number)."
    }
}

extension AttributedString {
    /// The part between two UTF-16 offsets into the characters. An offset
    /// inside a grapheme cluster rounds forward to the next boundary.
    func slice(utf16 range: Range<Int>) -> AttributedString {
        var lower: AttributedString.Index?
        var upper: AttributedString.Index?
        var count = 0
        var index = characters.startIndex
        while index < characters.endIndex {
            if lower == nil, count >= range.lowerBound { lower = index }
            if count >= range.upperBound {
                upper = index
                break
            }
            count += characters[index].utf16.count
            index = characters.index(after: index)
        }
        let start = lower ?? characters.endIndex
        let end = max(start, upper ?? characters.endIndex)
        return AttributedString(self[start..<end])
    }
}
