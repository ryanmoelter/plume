import Foundation

/// Builds and serializes the composer's `NSAttributedString` model.
///
/// The message goes to an LLM, not a renderer: `markdown(from:)` never
/// escapes a literal markdown character, and the round trip preserves
/// intentional formatting rather than being a bijection — one blank line
/// separates blocks on the way out regardless of how many separated them on
/// the way in, and list numbering/continuation is recomputed rather than
/// carried through verbatim.
nonisolated enum ComposerDocument {
    /// Builds attributed text from `markdown`. Unsupported block kinds
    /// (tables, rules — anything with no editing story) become `.verbatim`
    /// paragraphs holding their source text literally, one physical
    /// paragraph per source line, all sharing one `blockID` so they
    /// serialize back out as one block.
    ///
    /// Empty markdown returns an empty string with no attributes: a
    /// zero-length string can't usefully carry a typing kind, so the caller
    /// (the text view integration) is responsible for setting its own
    /// `typingAttributes` to `style.attributes(for: .paragraph)` when the
    /// document is empty.
    static func attributedString(markdown: String, style: ComposerTextStyle) -> NSAttributedString {
        let blocks = MarkdownBlock.parseWithSources(markdown)
        guard !blocks.isEmpty else { return NSAttributedString(string: "") }

        let result = NSMutableAttributedString()
        for (index, parsed) in blocks.enumerated() {
            append(parsed, isLastBlock: index == blocks.count - 1, to: result, style: style)
        }
        return result
    }

    /// Walks paragraphs, groups consecutive ones into blocks, and serializes
    /// each. Plain paragraphs and headings are never grouped with a
    /// neighbor even when adjacent — only list items, consecutive quote
    /// paragraphs, and paragraphs sharing a `blockID` merge — so a multi-line
    /// prose paragraph that round-tripped through here comes back as
    /// several single-line paragraphs. That's the documented non-bijection,
    /// not a bug.
    static func markdown(from attributed: NSAttributedString) -> String {
        ComposerParagraphs.runs(of: ComposerParagraphs.all(in: attributed), where: sharesBlock)
            .map { markdown(for: $0, attributed: attributed) }
            .joined(separator: "\n\n")
    }

    private static func sharesBlock(_ previous: ComposerParagraph, _ next: ComposerParagraph) -> Bool {
        let kind = previous.kind
        if kind.isList { return next.kind.isList }
        if case .quote = kind.kind { return next.kind.kind == .quote }
        return kind.hasOwnBlockID && next.kind == kind
    }

    // MARK: - Building

    private static func append(
        _ parsed: MarkdownBlock.Parsed,
        isLastBlock: Bool,
        to result: NSMutableAttributedString,
        style: ComposerTextStyle
    ) {
        switch parsed.block {
        case let .heading(level, text):
            let kind = ComposerBlockKind.heading(level)
            appendParagraph(
                ComposerInlineMarkdown.attributed(inline: text, kind: kind, style: style),
                kind: kind, isLast: isLastBlock, to: result, style: style
            )

        case let .paragraph(text):
            let kind = ComposerBlockKind.paragraph
            appendParagraph(
                ComposerInlineMarkdown.attributed(inline: text, kind: kind, style: style),
                kind: kind, isLast: isLastBlock, to: result, style: style
            )

        case let .quote(text, _):
            let lines = text.components(separatedBy: "\n")
            for (lineIndex, line) in lines.enumerated() {
                appendParagraph(
                    ComposerInlineMarkdown.attributed(inline: line, kind: .quote, style: style),
                    kind: .quote,
                    isLast: isLastBlock && lineIndex == lines.count - 1,
                    to: result, style: style
                )
            }

        case let .list(items):
            for (itemIndex, item) in items.enumerated() {
                let kind: ComposerBlockKind = item.isNumbered
                    ? .numbered(depth: item.depth, number: item.number ?? 1)
                    : .bullet(depth: item.depth)
                appendParagraph(
                    ComposerInlineMarkdown.attributed(inline: item.text, kind: kind, style: style),
                    kind: kind,
                    isLast: isLastBlock && itemIndex == items.count - 1,
                    to: result, style: style
                )
            }

        case let .codeBlock(language, code):
            let kind = ComposerBlockKind.codeBlock(language: language)
            let lines = code.components(separatedBy: "\n")
            for (lineIndex, line) in lines.enumerated() {
                appendLiteralParagraph(
                    line, kind: kind,
                    isFirstInBlock: lineIndex == 0,
                    isLastInBlock: lineIndex == lines.count - 1,
                    isLast: isLastBlock && lineIndex == lines.count - 1,
                    to: result, style: style
                )
            }

        case .table, .rule:
            let kind = ComposerBlockKind.verbatim()
            let lines = parsed.source.components(separatedBy: "\n")
            for (lineIndex, line) in lines.enumerated() {
                appendLiteralParagraph(
                    line, kind: kind,
                    isFirstInBlock: lineIndex == 0,
                    isLastInBlock: lineIndex == lines.count - 1,
                    isLast: isLastBlock && lineIndex == lines.count - 1,
                    to: result, style: style
                )
            }
        }
    }

    private static func appendParagraph(
        _ content: NSAttributedString,
        kind: ComposerBlockKind,
        isLast: Bool,
        to result: NSMutableAttributedString,
        style: ComposerTextStyle
    ) {
        result.append(content)
        if !isLast {
            result.append(NSAttributedString(string: "\n", attributes: style.attributes(for: kind)))
        }
    }

    private static func appendLiteralParagraph(
        _ text: String,
        kind: ComposerBlockKind,
        isFirstInBlock: Bool,
        isLastInBlock: Bool,
        isLast: Bool,
        to result: NSMutableAttributedString,
        style: ComposerTextStyle
    ) {
        let attributes = style.attributes(
            for: kind, isFirstInBlock: isFirstInBlock, isLastInBlock: isLastInBlock
        )
        result.append(NSAttributedString(string: text, attributes: attributes))
        if !isLast {
            result.append(NSAttributedString(string: "\n", attributes: attributes))
        }
    }

    // MARK: - Serializing

    private static func markdown(for group: ArraySlice<ComposerParagraph>, attributed: NSAttributedString) -> String {
        let kind = group.first!.kind
        switch kind.kind {
        case let .heading(level):
            let text = ComposerInlineMarkdown.markdown(from: attributed, range: group.first!.contentRange)
            return MarkdownSource.markdown(of: .heading(level: level, text: text))

        case .paragraph:
            let text = ComposerInlineMarkdown.markdown(from: attributed, range: group.first!.contentRange)
            return MarkdownSource.markdown(of: .paragraph(text))

        case .quote:
            let text = group.map { ComposerInlineMarkdown.markdown(from: attributed, range: $0.contentRange) }
                .joined(separator: "\n")
            return MarkdownSource.markdown(of: .quote(text))

        case .bullet, .numbered:
            let items = group.map { paragraph -> MarkdownBlock.ListItem in
                let text = ComposerInlineMarkdown.markdown(from: attributed, range: paragraph.contentRange)
                switch paragraph.kind.kind {
                case let .numbered(depth, number):
                    return MarkdownBlock.ListItem(text: text, depth: depth, number: number)
                default:
                    return MarkdownBlock.ListItem(text: text, depth: paragraph.kind.depth)
                }
            }
            return MarkdownSource.markdown(of: .list(items))

        case let .codeBlock(language):
            let code = group.map { (attributed.string as NSString).substring(with: $0.contentRange) }
                .joined(separator: "\n")
            return MarkdownSource.markdown(of: .codeBlock(language: language, code: code))

        case .verbatim:
            return group.map { (attributed.string as NSString).substring(with: $0.contentRange) }
                .joined(separator: "\n")
        }
    }
}
