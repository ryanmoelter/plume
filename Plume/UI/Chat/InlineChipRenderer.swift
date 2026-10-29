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
/// icons each link's chip leads with.
struct ReferenceChipDrawing {
    struct Icon {
        var symbol: String
        var color: Color
        var brand: ReferenceChipBrand?
    }

    var wash: Color
    var brandColor: Color
    var icons: [URL: Icon]
    var metrics: ReferenceChipMetrics
}

/// Paints a rounded chip behind every run carrying a `CodeChipAttribute` or
/// a `ReferenceChipAttribute`, and a reference chip's icons over its
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
    /// How far a chip reaches past its glyphs' ascent and descent. It
    /// stops short of the line above and below, leaving `lineGap` between
    /// chips on adjacent lines, so the padding only spends the line spacing.
    var verticalPad: CGFloat = Self.defaultVerticalPad
    var lineGap: CGFloat = 1
    var radius: CGFloat = 4

    static let defaultVerticalPad: CGFloat = 2

    enum Chip: Equatable {
        case code(Int)
        case reference(Int, URL)
    }

    /// One chip's rect on one line, and where its icons go when this is the
    /// line holding its placeholder.
    struct Placement {
        var chip: Chip
        var line: Int
        var firstCharacter: Text.Layout.CharacterIndex?
        var rect: CGRect
        var icons: ReferenceChipMetrics.IconRects?
    }

    private func chip(of run: Text.Layout.Run) -> Chip? {
        if let code = run[CodeChipAttribute.self] { return .code(code.id) }
        if let reference = run[ReferenceChipAttribute.self] { return .reference(reference.id, reference.url) }
        return nil
    }

    func placements(in layout: Text.Layout) -> [Placement] {
        var placements: [Placement] = []
        let lines = Array(layout)
        for (lineIndex, line) in lines.enumerated() {
            let reach = verticalReach(of: lineIndex, in: lines)
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
                let rect = rect(of: line[index..<next], opensLine: index == line.startIndex, in: line, reach: reach)
                var icons: ReferenceChipMetrics.IconRects?
                if case .reference(_, let url) = chip, let references,
                   let placeholder = (index..<next).first(where: { line[$0][ReferenceChipAttribute.self]?.isPlaceholder == true }) {
                    icons = references.metrics.iconRects(
                        leadingX: line[placeholder].typographicBounds.origin.x,
                        chipMidY: rect.midY,
                        brand: references.icons[url]?.brand
                    )
                }
                placements.append(Placement(
                    chip: chip,
                    line: lineIndex,
                    firstCharacter: line[index].characterIndices.first,
                    rect: rect,
                    icons: icons
                ))
                index = next
            }
        }
        return placements
    }

    /// Fades each chip with the word it opens, so a chip never shows ahead of
    /// its text.
    func draw(layout: Text.Layout, reveal: WordReveal?, in context: inout GraphicsContext) {
        let origin = layout.lazy.compactMap { $0.first?.characterIndices.first }.first
        let lineStarts = reveal.flatMap { reveal in
            origin.map { WordReveal.lineStarts(of: layout, from: $0, paragraphStarts: reveal.paragraphStarts) }
        }
        for placement in placements(in: layout) {
            var chipContext = context
            if let reveal, let origin, let lineStarts, let first = placement.firstCharacter {
                chipContext.opacity = reveal.opacity(at: lineStarts[placement.line] + origin.distance(to: first))
            }
            guard chipContext.opacity > 0 else { continue }
            let path = Path(roundedRect: placement.rect, cornerRadius: radius)
            chipContext.fill(path, with: .color(fill))
            guard case .reference(_, let url) = placement.chip, let references else { continue }
            chipContext.fill(path, with: .color(references.wash))
            guard let icon = references.icons[url], let rects = placement.icons else { continue }
            if let brand = icon.brand, let brandRect = rects.brand {
                let inset = brandRect.width * (1 - ReferenceChipMetrics.brandScale) / 2
                drawLogo(brand, color: references.brandColor, in: brandRect.insetBy(dx: inset, dy: inset), context: &chipContext)
            }
            var symbol = chipContext.resolve(Image(systemName: icon.symbol))
            symbol.shading = .color(icon.color)
            if let rect = Self.fitted(symbol.size, in: rects.status) {
                chipContext.draw(symbol, in: rect)
            }
        }
    }

    /// An asset-catalog image given a shading draws nothing here, so the
    /// logo is a mask the color fills.
    private func drawLogo(_ brand: ReferenceChipBrand, color: Color, in square: CGRect, context: inout GraphicsContext) {
        let logo = context.resolve(Image(brand.imageName))
        guard let rect = Self.fitted(logo.size, in: square) else { return }
        context.drawLayer { layer in
            layer.clipToLayer { mask in mask.draw(logo, in: rect) }
            layer.fill(Path(rect), with: .color(color))
        }
    }

    /// `natural` scaled to fit `square`, centered in it.
    private static func fitted(_ natural: CGSize, in square: CGRect) -> CGRect? {
        guard natural.width > 0, natural.height > 0 else { return nil }
        let scale = min(square.width / natural.width, square.height / natural.height)
        let size = CGSize(width: natural.width * scale, height: natural.height * scale)
        return CGRect(x: square.midX - size.width / 2, y: square.midY - size.height / 2, width: size.width, height: size.height)
    }

    /// The room a chip on a `Text`'s first or last line reaches past it. A
    /// renderer drawing chips must return this as its `displayPadding`, or
    /// those chips are cut off at the line's edge.
    var displayPadding: EdgeInsets {
        EdgeInsets(top: verticalPad, leading: 0, bottom: verticalPad, trailing: 0)
    }

    /// The lowest top and highest bottom a chip on line `index` may reach.
    /// A line with no neighbor on a side takes the whole `verticalPad`.
    private func verticalReach(of index: Int, in lines: [Text.Layout.Line]) -> (top: CGFloat, bottom: CGFloat) {
        func top(_ line: Text.Layout.Line) -> CGFloat { line.typographicBounds.origin.y - line.typographicBounds.ascent }
        func bottom(_ line: Text.Layout.Line) -> CGFloat { line.typographicBounds.origin.y + line.typographicBounds.descent }
        let line = lines[index]
        let above = index > 0 ? max(0, (top(line) - bottom(lines[index - 1]) - lineGap) / 2) : verticalPad
        let below = index + 1 < lines.count ? max(0, (top(lines[index + 1]) - bottom(line) - lineGap) / 2) : verticalPad
        return (top(line) - above, bottom(line) + below)
    }

    /// Spans every run of the chip on this line, so a chip whose placeholder
    /// falls back to another font is as tall as its title.
    private func rect(
        of runs: Text.Layout.Line.SubSequence,
        opensLine: Bool,
        in line: Text.Layout.Line,
        reach: (top: CGFloat, bottom: CGFloat)
    ) -> CGRect {
        let firstBounds = runs[runs.startIndex].typographicBounds
        let lastBounds = runs[runs.index(before: runs.endIndex)].typographicBounds
        let leading = firstBounds.origin.x - (opensLine ? 0 : pad)
        let trailing = lastBounds.origin.x + lastBounds.width
        let ascent = runs.map { $0.typographicBounds.origin.y - $0.typographicBounds.ascent }.min() ?? firstBounds.origin.y
        let descent = runs.map { $0.typographicBounds.origin.y + $0.typographicBounds.descent }.max() ?? firstBounds.origin.y
        let top = max(ascent - verticalPad, reach.top)
        let bottom = min(descent + verticalPad, reach.bottom)
        return CGRect(x: leading, y: top, width: trailing - leading, height: bottom - top)
    }
}

/// A `Text`'s chips, then its glyphs: faded by the reveal when there is one,
/// whole otherwise. A `Text` takes one renderer, so this one carries the
/// reveal.
struct InlineChipRenderer: TextRenderer {
    var chips: InlineChips
    var reveal: WordReveal?

    var displayPadding: EdgeInsets { chips.displayPadding }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        chips.draw(layout: layout, reveal: reveal, in: &context)
        if let reveal {
            reveal.draw(layout: layout, in: &context)
        } else {
            layout.forEach { context.draw($0) }
        }
    }
}
