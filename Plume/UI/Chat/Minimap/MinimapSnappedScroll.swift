import Foundation

/// A debug alternative to scrolling the map continuously while hovering: the
/// drawn offset holds still while the hovered row stays the same, and steps
/// to the catch-up's offset only when the hovered row changes.
///
/// The hovered row is always the row under the pointer at the drawn offset,
/// so a click or the preview lands on what is drawn.
enum MinimapSnappedScroll {
    struct Step: Equatable {
        var rowID: String?
        var offset: CGFloat
    }

    /// `rowAt` names the row under the pointer when the map is scrolled to
    /// the given offset.
    static func step(
        hoveredRowID: String?,
        displayed: CGFloat,
        target: CGFloat,
        rowAt: (CGFloat) -> String?
    ) -> Step {
        let drawnRow = rowAt(displayed)
        guard drawnRow != hoveredRowID else { return Step(rowID: hoveredRowID, offset: displayed) }
        let targetRow = rowAt(target)
        // At the target the pointer would be back on the row it just left,
        // so stepping there would scroll without changing the row.
        guard targetRow != hoveredRowID else { return Step(rowID: drawnRow, offset: displayed) }
        return Step(rowID: targetRow, offset: target)
    }
}
