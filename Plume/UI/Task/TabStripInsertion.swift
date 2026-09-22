import CoreGraphics

/// Where a tab dragged along the strip would land, as a gap between chips.
///
/// Gap `i` sits before chip `i`, and gap `chips.count` after the last one,
/// which is also the `toOffset` that `Array.move(fromOffsets:toOffset:)`
/// takes.
enum TabStripInsertion {
    /// The gap nearest `x`: a pointer over a chip's leading half lands before
    /// it, over its trailing half after it.
    static func gap(forX x: CGFloat, chips: [ClosedRange<CGFloat>]) -> Int {
        chips.firstIndex { x < ($0.lowerBound + $0.upperBound) / 2 } ?? chips.count
    }

    /// The center of `gap`: midway between its neighbors, or `spacing / 2`
    /// outside the chip at either end.
    static func markerX(gap: Int, chips: [ClosedRange<CGFloat>], spacing: CGFloat) -> CGFloat? {
        guard !chips.isEmpty, (0...chips.count).contains(gap) else { return nil }
        if gap == 0 { return chips[0].lowerBound - spacing / 2 }
        if gap == chips.count { return chips[gap - 1].upperBound + spacing / 2 }
        return (chips[gap - 1].upperBound + chips[gap].lowerBound) / 2
    }
}
