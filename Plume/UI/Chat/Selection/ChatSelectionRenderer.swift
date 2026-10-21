import AppKit
import SwiftUI

/// Draws a chat `Text` with its share of the transcript's selection behind
/// it, and the word reveal over that when the reveal has not passed it.
///
/// SwiftUI's own selection draws without consulting a `TextRenderer`, which
/// is why the transcript does its own.
struct ChatSelectionRenderer: TextRenderer {
    var reveal: WordReveal?
    /// This `Text`'s own offsets.
    var selected: Range<Int>?
    var highlight: Color
    var text: String

    func draw(layout: Text.Layout, in ctx: inout GraphicsContext) {
        if let selected, !selected.isEmpty { fillSelection(selected, layout: layout, in: &ctx) }
        if let reveal {
            reveal.draw(layout: layout, in: &ctx)
        } else {
            layout.forEach { ctx.draw($0) }
        }
    }

    /// One band per line, from the first selected glyph to the last, the
    /// line's full height.
    private func fillSelection(_ selected: Range<Int>, layout: Text.Layout, in ctx: inout GraphicsContext) {
        guard let origin = ChatTextGeometry.origin(of: layout) else { return }
        let lineStarts = WordReveal.lineStarts(
            of: layout, from: origin, paragraphStarts: WordReveal.paragraphStarts(in: text)
        )
        for (line, lineStart) in zip(layout, lineStarts) {
            var band: CGRect?
            for run in line {
                for slice in run {
                    guard let index = slice.characterIndices.first,
                          selected.contains(lineStart + origin.distance(to: index)) else { continue }
                    let rect = slice.typographicBounds.rect
                    band = band.map { $0.union(rect) } ?? rect
                }
            }
            guard let band else { continue }
            let lineRect = line.typographicBounds.rect
            ctx.fill(Path(CGRect(x: band.minX, y: lineRect.minY, width: band.width, height: lineRect.height)), with: .color(highlight))
        }
    }
}

/// Records a selectable `Text`'s layout and frame for hit-testing. Both
/// arrive in callbacks rather than during `body` or a draw.
struct ChatSelectionRecorder: ViewModifier {
    let span: ChatSelectionSpan
    let text: String
    @State private var owner = UUID()

    func body(content: Content) -> some View {
        let registry = span.store.layouts
        let pieceID = span.pieceID
        let offset = span.offset
        let text = text
        let owner = owner
        content
            .onPreferenceChange(Text.LayoutKey.self) { layouts in
                let layout = layouts.first?.layout
                MainActor.assumeIsolated {
                    registry.setLayout(layout, text: text, pieceID: pieceID, offset: offset, owner: owner)
                }
            }
            .onGeometryChange(for: CGRect.self) {
                $0.frame(in: .named(ChatSelectionGeometry.rowSpace))
            } action: { frame in
                registry.setFrame(frame, text: text, pieceID: pieceID, offset: offset, owner: owner)
            }
            .onDisappear { registry.remove(pieceID, offset: offset, owner: owner) }
    }
}

extension PieceSelection {
    func highlight(accent: Color) -> Color {
        isActive ? accent.opacity(0.3) : Color(nsColor: .unemphasizedSelectedTextBackgroundColor)
    }
}
