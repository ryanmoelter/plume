import SwiftUI

/// Marks the runs of one inline code span within a `Text`, so
/// `CodeChipRenderer` knows which runs to paint a chip behind.
///
/// Distinct per span (never a shared constant) so two adjacent chips on the
/// same line don't merge into one rounded rect.
struct CodeChipAttribute: TextAttribute, Hashable {
    var id: Int
}

/// Paints a rounded chip behind every run carrying a `CodeChipAttribute`.
///
/// A chip can split into several runs on one line — mixed fonts, or the kern
/// boundary between the preceding text and the chip — so consecutive runs
/// with the same id are unioned into one rect. A chip that wraps yields one
/// run group per line; the group that opens a wrapped line is a continuation
/// and gets no leading pad reclaimed.
struct CodeChipRenderer: TextRenderer {
    var pad: CGFloat
    var vpad: CGFloat = 1.5
    var radius: CGFloat = 4
    var fill: Color

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
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
                let first = line[index].typographicBounds
                let last = line[next - 1].typographicBounds
                let leading = first.origin.x - (index == line.startIndex ? 0 : pad)
                let trailing = last.origin.x + last.width
                let top = max(first.origin.y - first.ascent - vpad, line.origin.y - line.typographicBounds.ascent)
                let bottom = min(first.origin.y + first.descent + vpad, line.origin.y + line.typographicBounds.descent)
                let rect = CGRect(x: leading, y: top, width: trailing - leading, height: bottom - top)
                context.fill(Path(roundedRect: rect, cornerRadius: radius), with: .color(fill))
                index = next
            }
            for run in line {
                context.draw(run)
            }
        }
    }
}

extension View {
    /// Applies `CodeChipRenderer` for a `StyledInline` that contains at least
    /// one code span, and leaves a plain `Text` on the plain rendering path
    /// otherwise — a `TextRenderer` is not free to attach to text that never
    /// needs one.
    @ViewBuilder
    func codeChips(_ styled: StyledInline, fill: Color) -> some View {
        if styled.hasCode {
            textRenderer(CodeChipRenderer(pad: styled.pad, fill: fill))
        } else {
            self
        }
    }
}
