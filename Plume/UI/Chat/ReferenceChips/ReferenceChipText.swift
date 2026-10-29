import Foundation

/// The text side of a chat reference chip.
///
/// A chip's title is written into the block's markdown when the pieces are
/// built, `[DROID-123](url)` becoming `[\u{202F}Fix the layout](url)`, because
/// the reveal, selection, hit-testing and copy all count characters in that
/// text. Swapping the label at render time would desync all of them. The
/// leading narrow no-break space marks the link as a chip and holds the room
/// its icon draws in.
nonisolated enum ReferenceChipText {
    static let placeholder: Character = "\u{202F}"
    static let maxTitleLength = 40

    /// Whitespace collapsed to single spaces, and anything past
    /// `maxTitleLength` characters cut to an ellipsis.
    static func truncatedTitle(_ title: String) -> String {
        let collapsed = title.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        guard collapsed.count > maxTitleLength else { return collapsed }
        var cut = String(collapsed.prefix(maxTitleLength - 1))
        while let last = cut.last, last.isWhitespace { cut.removeLast() }
        return cut + "…"
    }

    /// `text` with every character inline markdown or a table cell could
    /// read as syntax backslash-escaped, so it reads back exactly as written.
    static func escaped(_ text: String) -> String {
        var out = ""
        for character in text {
            if escapedCharacters.contains(character) { out.append("\\") }
            out.append(character)
        }
        return out
    }

    private static let escapedCharacters: Set<Character> = ["\\", "`", "*", "_", "[", "]", "<", ">", "~", "&", "|", "!"]

    /// `text` with each link whose destination has a title given rewritten as
    /// a chip. Images and links inside code are left alone, and so is every
    /// destination, byte for byte.
    static func rewrite(_ text: String, title: (_ destination: String) -> String?) -> String {
        let links = MarkdownHighlighter.linkRanges(in: text)
        guard !links.isEmpty else { return text }
        let ns = text as NSString
        let rewritten = NSMutableString(string: text)
        for link in links.reversed() where !link.isImage {
            guard let title = title(ns.substring(with: link.destination)) else { continue }
            rewritten.replaceCharacters(in: link.label, with: chipLabel(title))
        }
        return rewritten as String
    }

    static func chipLabel(_ title: String) -> String {
        String(placeholder) + escaped(truncatedTitle(title))
    }

    /// `text` with every chip's label put back to the reference's canonical
    /// label, for copying a piece the splitter wrote back from its blocks.
    static func restoringCanonical(in text: String) -> String {
        let links = MarkdownHighlighter.linkRanges(in: text)
        guard !links.isEmpty else { return text }
        let ns = text as NSString
        let restored = NSMutableString(string: text)
        for link in links.reversed() where !link.isImage {
            guard ns.substring(with: link.label).first == placeholder else { continue }
            let label = url(forDestination: ns.substring(with: link.destination)).flatMap(canonicalLabel(for:))
            restored.replaceCharacters(in: link.label, with: escaped(label ?? ""))
        }
        return restored as String
    }

    /// The canonical label of the reference `url` names. Needs no base: a
    /// file's label is only its name.
    static func canonicalLabel(for url: URL) -> String? {
        if let target = ReferenceTarget.classify(url, base: URL(fileURLWithPath: "/")) {
            if case .file = target, url.absoluteString.split(separator: "#").first?.hasSuffix("/") == true {
                return target.canonicalLabel + "/"
            }
            return target.canonicalLabel
        }
        return nil
    }

    /// The URL a link destination parses to, the way the chat renders it.
    static func url(forDestination destination: String) -> URL? {
        let parsed = try? AttributedString(
            markdown: "[x](\(destination))",
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )
        return parsed?.runs.lazy.compactMap(\.link).first
    }

    static func isChipLabel(_ label: some StringProtocol) -> Bool {
        label.first == placeholder
    }
}

extension MarkdownBlock {
    /// The block with `transform` applied to each run of inline markdown it
    /// holds. Code blocks and rules have none.
    nonisolated func mappingInline(_ transform: (String) -> String) -> MarkdownBlock {
        switch self {
        case let .heading(level, text): .heading(level: level, text: transform(text))
        case let .paragraph(text): .paragraph(transform(text))
        case let .quote(text, continues): .quote(transform(text), continues: continues)
        case let .list(items):
            .list(items.map { item in
                var item = item
                item.text = transform(item.text)
                return item
            })
        case let .table(header, alignments, rows):
            .table(header: header.map(transform), alignments: alignments, rows: rows.map { $0.map(transform) })
        case .codeBlock, .rule: self
        }
    }
}
