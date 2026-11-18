import Foundation

/// How a hover draws the map: it scrolls only when the hovered row changes.
/// `MinimapHoverScroll` runs on every pointer move, and the hovered row is
/// the one under the pointer at its offset; the drawn offset holds while
/// that row stays the same. When the row changes it steps to the catch-up's
/// offset with the pointer moved on to the new row's middle.
enum MinimapSnappedScroll {
    struct Step: Equatable {
        var rowID: String?
        var offset: CGFloat
    }

    /// `rowAt` names the row under the pointer when the map is scrolled to
    /// the given offset, and `project` gives the offset to draw a newly
    /// hovered row at. The first row of a hover draws at `target`, since no
    /// move has headed anywhere yet.
    static func step(
        hoveredRowID: String?,
        displayed: CGFloat,
        target: CGFloat,
        rowAt: (CGFloat) -> String?,
        project: (String) -> CGFloat
    ) -> Step {
        let row = rowAt(target)
        guard let row, row != hoveredRowID else { return Step(rowID: row, offset: displayed) }
        guard hoveredRowID != nil else { return Step(rowID: row, offset: target) }
        return Step(rowID: row, offset: project(row))
    }

    /// The offset `scroll` reaches when the pointer moves on from `pointerY`
    /// until the content under it is `rowY`, through the same catch-up and
    /// dead zone the hover runs. The pointer stops at the rail's ends, so a
    /// row it can't bring under the pointer gets the offset at that end.
    static func projectedOffset(
        of scroll: MinimapHoverScroll,
        pointerY: CGFloat,
        toRowAt rowY: CGFloat,
        metrics: MinimapMetrics,
        centering: CGFloat,
        gain: CGFloat
    ) -> CGFloat {
        func contentY(_ state: MinimapHoverScroll, _ y: CGFloat) -> CGFloat {
            y - metrics.topMargin - centering + state.offset
        }
        func advanced(_ state: MinimapHoverScroll, to y: CGFloat) -> MinimapHoverScroll {
            var next = state
            next.move(
                to: MinimapCatchUp.absolute(pointerFraction: metrics.pointerFraction(atY: y)),
                pointerY: y,
                travel: metrics.travel,
                gain: gain
            )
            return next
        }
        let start = contentY(scroll, pointerY)
        guard start != rowY else { return scroll.offset }
        let direction: CGFloat = rowY > start ? 1 : -1
        func reached(_ state: MinimapHoverScroll, _ y: CGFloat) -> Bool {
            (rowY - contentY(state, y)) * direction <= 0
        }
        let limit = direction > 0 ? metrics.drawableBottom : 0
        var state = scroll
        var y = pointerY
        while (limit - y) * direction > 0 {
            let nextY = direction > 0 ? min(y + substep, limit) : max(y - substep, limit)
            let next = advanced(state, to: nextY)
            guard reached(next, nextY) else {
                state = next
                y = nextY
                continue
            }
            var short: CGFloat = 0
            var long = abs(nextY - y)
            for _ in 0..<24 {
                let middle = (short + long) / 2
                if reached(advanced(state, to: y + direction * middle), y + direction * middle) {
                    long = middle
                } else {
                    short = middle
                }
            }
            return advanced(state, to: y + direction * long).offset
        }
        return state.offset
    }

    /// The pointer move the projection takes at a time, finer than a real
    /// pointer's, since the catch-up's result depends on the moves' size.
    private static let substep: CGFloat = 0.5
}
