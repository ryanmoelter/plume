import SwiftUI

/// Lays a markdown table's cells out the way an HTML table does: columns take
/// the width their content asks for, and only shrink when the row of them
/// doesn't fit.
///
/// SwiftUI's `Grid` cannot do this. A cell there must claim the full width to
/// fill its column — which is what lets a fill or a rule cover the whole cell
/// rather than just its text — and a column of full-width claims makes `Grid`
/// divide the space equally. Measuring and placing by hand separates the two:
/// a column is sized by what its text *ideally* wants, then every cell in it
/// is handed that full width to occupy.
///
/// Subviews arrive in row-major order and every row carries `columnCount` of
/// them, including the empty cells that pad a ragged row.
nonisolated struct TableLayout: Layout {
    let columnCount: Int

    /// The widths each column would take if nothing constrained them, and the
    /// widths they actually get. Computed once per pass and reused by
    /// `placeSubviews`, which would otherwise measure everything again.
    struct Cache {
        var ideal: [CGFloat] = []
        var resolved: [CGFloat] = []
        var proposedWidth: CGFloat?
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache = Cache()
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) -> CGSize {
        guard columnCount > 0, !subviews.isEmpty else { return .zero }
        resolveColumns(proposal: proposal, subviews: subviews, cache: &cache)

        let width = cache.resolved.reduce(0, +)
        let height = rowHeights(subviews: subviews, widths: cache.resolved).reduce(0, +)
        return CGSize(width: width, height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) {
        guard columnCount > 0, !subviews.isEmpty else { return }
        resolveColumns(proposal: proposal, subviews: subviews, cache: &cache)

        let widths = cache.resolved
        let heights = rowHeights(subviews: subviews, widths: widths)

        var y = bounds.minY
        for row in 0..<heights.count {
            var x = bounds.minX
            for column in 0..<columnCount {
                guard let subview = subview(subviews, row: row, column: column) else { continue }
                subview.place(
                    at: CGPoint(x: x, y: y),
                    proposal: ProposedViewSize(width: widths[column], height: heights[row])
                )
                x += widths[column]
            }
            y += heights[row]
        }
    }

    /// Each column's ideal width, then those widths fitted to the space on
    /// offer.
    private func resolveColumns(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) {
        let available = proposal.width
        guard cache.resolved.isEmpty || cache.proposedWidth != available else { return }
        cache.proposedWidth = available

        if cache.ideal.isEmpty {
            cache.ideal = (0..<columnCount).map { column in
                rowIndices(subviews: subviews).reduce(CGFloat.zero) { widest, row in
                    guard let subview = subview(subviews, row: row, column: column) else {
                        return widest
                    }
                    return max(widest, subview.sizeThatFits(.unspecified).width)
                }
            }
        }

        cache.resolved = fitted(cache.ideal, into: available)
    }

    /// Columns at their ideal widths, or shrunk to fit when those overflow.
    ///
    /// Shrinking takes from the widest column first, which keeps a table's
    /// narrow columns — a count, a price — intact and wraps the prose column
    /// that has room to give.
    private func fitted(_ ideal: [CGFloat], into available: CGFloat?) -> [CGFloat] {
        let total = ideal.reduce(0, +)
        guard let available, total > available else { return ideal }

        var widths = ideal
        var excess = total - available
        // Repeatedly level the widest column down to the next widest, so the
        // columns that must shrink end up sharing one width rather than the
        // first one taking the whole reduction.
        while excess > 0.5 {
            let widest = widths.max() ?? 0
            let widestIndices = widths.indices.filter { widths[$0] >= widest - 0.5 }
            guard widestIndices.count < widths.count else {
                // Every column is equally wide: take the rest evenly.
                let each = excess / CGFloat(widths.count)
                return widths.map { max(0, $0 - each) }
            }
            let runnerUp = widths.filter { $0 < widest - 0.5 }.max() ?? 0
            let headroom = (widest - runnerUp) * CGFloat(widestIndices.count)
            let taken = min(excess, headroom)
            let each = taken / CGFloat(widestIndices.count)
            for index in widestIndices { widths[index] -= each }
            excess -= taken
        }
        return widths
    }

    /// Each row's height, being the tallest cell in it at its column's width.
    private func rowHeights(subviews: Subviews, widths: [CGFloat]) -> [CGFloat] {
        rowIndices(subviews: subviews).map { row in
            (0..<columnCount).reduce(CGFloat.zero) { tallest, column in
                guard let subview = subview(subviews, row: row, column: column) else {
                    return tallest
                }
                let size = subview.sizeThatFits(
                    ProposedViewSize(width: widths[column], height: nil)
                )
                return max(tallest, size.height)
            }
        }
    }

    private func rowIndices(subviews: Subviews) -> Range<Int> {
        0..<Int(ceil(Double(subviews.count) / Double(columnCount)))
    }

    private func subview(_ subviews: Subviews, row: Int, column: Int) -> Subviews.Element? {
        let index = row * columnCount + column
        return subviews.indices.contains(index) ? subviews[index] : nil
    }
}
