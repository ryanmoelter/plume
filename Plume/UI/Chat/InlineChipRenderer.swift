import SwiftUI

/// Marks the runs of one inline code span within a `Text`, so `InlineChips`
/// knows which runs to paint a chip behind.
///
/// Distinct per span, so two adjacent chips on one line don't merge into one
/// rounded rect.
struct CodeChipAttribute: TextAttribute, Hashable {
    var id: Int
}

/// Marks the runs of one reference chip within a `Text`. Its placeholder,
/// the narrow space its icon draws over, is a run of its own.
struct ReferenceChipAttribute: TextAttribute, Hashable {
    var id: Int
    var url: URL
    var isPlaceholder: Bool
}

/// How a `Text`'s reference chips draw: the wash over the code fill, and the
/// icon each link's chip leads with.
struct ReferenceChipDrawing {
    struct Icon {
        var symbol: String
        var color: Color
    }

    var wash: Color
    var icons: [URL: Icon]
    var iconSize: CGFloat
}

/// Paints a rounded chip behind every run carrying a `CodeChipAttribute` or
/// a `ReferenceChipAttribute`, and a reference chip's icon over its
/// placeholder.
///
/// A chip can split into several runs on one line — mixed fonts, or the kern
/// boundary with the text before it — so consecutive runs of the same chip
/// are unioned into one rect. A chip that wraps yields one rect per line, and
/// the rect opening a line reaches no further left than the line does.
struct InlineChips {
    /// The kern `MarkdownCache.chippedInline` puts on either side of a chip.
    var pad: CGFloat
    var fill: Color
    var references: ReferenceChipDrawing?
    var verticalPad: CGFloat = 1.5
    var radius: CGFloat = 4

    private enum Chip: Equatable {
        case code(Int)
        case reference(Int, URL)
    }

    private func chip(of run: Text.Layout.Run) -> Chip? {
        if let code = run[CodeChipAttribute.self] { return .code(code.id) }
        if let reference = run[ReferenceChipAttribute.self] { return .reference(reference.id, reference.url) }
        return nil
    }

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
                guard let chip = chip(of: line[index]) else {
                    index += 1
                    continue
                }
                var next = index + 1
                while next < line.endIndex, self.chip(of: line[next]) == chip {
                    next += 1
                }
                var chipContext = context
                if let reveal, let origin, let lineStarts,
                   let first = line[index].characterIndices.first {
                    chipContext.opacity = reveal.opacity(at: lineStarts[lineIndex] + origin.distance(to: first))
                }
                if chipContext.opacity > 0 {
                    let rect = rect(from: line[index], through: line[next - 1], opensLine: index == line.startIndex, in: line)
                    let path = Path(roundedRect: rect, cornerRadius: radius)
                    chipContext.fill(path, with: .color(fill))
                    if case .reference(_, let url) = chip, let references {
                        chipContext.fill(path, with: .color(references.wash))
                        if let icon = references.icons[url],
                           let placeholder = (index..<next).first(where: { line[$0][ReferenceChipAttribute.self]?.isPlaceholder == true }) {
                            drawIcon(icon, size: references.iconSize, over: line[placeholder], in: &chipContext)
                        }
                    }
                }
                index = next
            }
        }
    }

    /// Fitted into a square the icon's size, leading the placeholder and
    /// centered on the line's text.
    private func drawIcon(_ icon: ReferenceChipDrawing.Icon, size: CGFloat, over run: Text.Layout.Run, in context: inout GraphicsContext) {
        var image = context.resolve(Image(systemName: icon.symbol))
        image.shading = .color(icon.color)
        let natural = image.size
        guard natural.width > 0, natural.height > 0 else { return }
        let scale = size / max(natural.width, natural.height)
        let width = natural.width * scale
        let height = natural.height * scale
        let bounds = run.typographicBounds
        let center = bounds.origin.y - (bounds.ascent - bounds.descent) / 2
        let rect = CGRect(x: bounds.origin.x + (size - width) / 2, y: center - height / 2, width: width, height: height)
        context.draw(image, in: rect)
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

/// A `Text`'s chips, then its glyphs: faded by the reveal when there is one,
/// whole otherwise. A `Text` takes one renderer, so this one carries the
/// reveal.
struct InlineChipRenderer: TextRenderer {
    var chips: InlineChips
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
