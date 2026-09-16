import SwiftUI

/// A row of views that wraps to the next line when it runs out of width, so a
/// sentence built from mixed views — words and controls — breaks like prose.
///
/// Each subview keeps its ideal size; only where a line breaks is decided
/// here. Views on one line are centered against each other vertically, which
/// is what keeps a menu's label sitting on the same baseline as the words
/// around it.
nonisolated struct WrappingHStack: Layout {
    var horizontalSpacing: CGFloat = 4
    var verticalSpacing: CGFloat = 4
    var alignment: HorizontalAlignment = .leading

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(within: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +)
            + verticalSpacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = rows(within: bounds.width, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX + leadingOffset(rowWidth: row.width, in: bounds.width)
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + horizontalSpacing
            }
            y += row.height + verticalSpacing
        }
    }

    private func leadingOffset(rowWidth: CGFloat, in containerWidth: CGFloat) -> CGFloat {
        switch alignment {
        case .center: max(0, (containerWidth - rowWidth) / 2)
        case .trailing: max(0, containerWidth - rowWidth)
        default: 0
        }
    }

    /// The break points, as index runs. A subview wider than the whole
    /// container still gets a line of its own rather than an empty one before
    /// it, so a long folder name degrades to overflow instead of a blank gap.
    private func rows(within width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + horizontalSpacing + size.width
            if !current.indices.isEmpty, needed > width {
                rows.append(current)
                current = Row()
                current.add(index: index, size: size, spacing: horizontalSpacing)
            } else {
                current.add(index: index, size: size, spacing: horizontalSpacing)
            }
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0

        mutating func add(index: Int, size: CGSize, spacing: CGFloat) {
            width += indices.isEmpty ? size.width : spacing + size.width
            height = max(height, size.height)
            indices.append(index)
        }
    }
}
