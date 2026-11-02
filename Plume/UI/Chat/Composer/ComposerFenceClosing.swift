import Foundation

/// Typing the third backtick or tilde of an opening fence adds the closing
/// fence on the next line and leaves the caret after the typed fence.
nonisolated enum ComposerFenceClosing {
    /// `text` and `caret` are the state after the character was typed. Nil
    /// when the typed run is not an opening fence that would stay open to the
    /// end of the text.
    static func closing(in text: String, caret: Int) -> ComposerMarkdownEditing.Result? {
        let ns = text as NSString
        let lines = MarkdownLineStructure.lines(in: text)
        guard let index = lines.lastIndex(where: { $0.range.location <= caret }) else { return nil }
        let line = lines[index]
        guard line.kind == .fence, caret == NSMaxRange(line.range) else { return nil }

        let fence = ns.substring(with: NSRange(location: NSMaxRange(line.indent), length: NSMaxRange(line.range) - NSMaxRange(line.indent)))
        guard fence == "```" || fence == "~~~" else { return nil }

        let fenceLines = lines.indices.filter { lines[$0].kind == .fence }
        guard fenceLines.last == index, fenceLines.count % 2 == 1 else { return nil }

        let prefix = ns.substring(with: NSRange(location: line.range.location, length: NSMaxRange(line.indent) - line.range.location))
        let insertion = "\n" + prefix + fence
        return ComposerMarkdownEditing.Result(
            text: ns.replacingCharacters(in: NSRange(location: caret, length: 0), with: insertion),
            selection: NSRange(location: caret, length: 0)
        )
    }
}
