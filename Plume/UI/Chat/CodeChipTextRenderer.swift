import SwiftUI

/// Marks the runs of one inline code span within a `Text`, so `CodeChips`
/// knows which runs to paint a chip behind.
///
/// Distinct per span, so two adjacent chips on one line don't merge into one
/// rounded rect.
struct CodeChipAttribute: TextAttribute, Hashable {
    var id: Int
}

/// Paints a rounded chip behind every run carrying a `CodeChipAttribute`.
///
/// A chip can split into several runs on one line — mixed fonts, or the kern
/// boundary with the text before it — so consecutive runs with the same id
/// are unioned into one rect. A chip that wraps yields one rect per line, and
/// the rect opening a line reaches no further left than the line does.
struct CodeChips {
    /// The kern `MarkdownCache.chippedInline` puts on either side of a chip.
    var pad: CGFloat
    var fill: Color
    var verticalPad: CGFloat = 1.5
    var radius: CGFloat = 4

    /// Fades each chip with the word it opens, so a chip never shows ahead of
    /// its text.
    func draw(layout: Text.Layout, reveal: WordReveal?, in context: inout GraphicsContext) {
        let origin = layout.lazy.compactMap { $0.first?.characterIndices.first }.first
        let lineStarts = reveal.flatMap { reveal in
            origin.map { WordReveal.lineStarts(of: layout, from: $0, paragraphStarts: reveal.paragraphStarts) }
        }
        for (lineIndex, line) in layout.enumerated() {
            var index = line.startIndex
            while index < line.endIndex {
                guard let chip = line[index][CodeChipAttribute.self] else {
                    index += 1
                    continue
                }
                var next = index + 1
                while next < line.endIndex, line[next][CodeChipAttribute.self] == chip {
                    next += 1
                }
                var chipContext = context
                if let reveal, let origin, let lineStarts,
                   let first = line[index].characterIndices.first {
                    chipContext.opacity = reveal.opacity(at: lineStarts[lineIndex] + origin.distance(to: first))
                }
                if chipContext.opacity > 0 {
                    let rect = rect(from: line[index], through: line[next - 1], opensLine: index == line.startIndex, in: line)
                    chipContext.fill(Path(roundedRect: rect, cornerRadius: radius), with: .color(fill))
                }
                index = next
            }
        }
    }

    private func rect(
        from first: Text.Layout.Run,
        through last: Text.Layout.Run,
        opensLine: Bool,
        in line: Text.Layout.Line
    ) -> CGRect {
        let firstBounds = first.typographicBounds
        let lastBounds = last.typographicBounds
        let lineBounds = line.typographicBounds
        let leading = firstBounds.origin.x - (opensLine ? 0 : pad)
        let trailing = lastBounds.origin.x + lastBounds.width
        let top = max(firstBounds.origin.y - firstBounds.ascent - verticalPad, lineBounds.origin.y - lineBounds.ascent)
        let bottom = min(firstBounds.origin.y + firstBounds.descent + verticalPad, lineBounds.origin.y + lineBounds.descent)
        return CGRect(x: leading, y: top, width: trailing - leading, height: bottom - top)
    }
}

/// A `Text`'s code chips, then its glyphs: faded by the reveal when there is
/// one, whole otherwise. A `Text` takes one renderer, so this one carries the
/// reveal.
struct CodeChipRenderer: TextRenderer {
    var chips: CodeChips
    var reveal: WordReveal?

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        chips.draw(layout: layout, reveal: reveal, in: &context)
        if let reveal {
            reveal.draw(layout: layout, in: &context)
        } else {
            layout.forEach { context.draw($0) }
        }
    }
}
