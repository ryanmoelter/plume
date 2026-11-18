import Foundation

/// A debug alternative to scrolling the map continuously while hovering. The
/// hovered row is always the one the continuous scroll would pick; only the
/// drawn offset is sticky, holding while that row stays the same and stepping
/// to the catch-up's offset when it changes.
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
        let row = rowAt(target)
        guard let row, row != hoveredRowID else { return Step(rowID: row, offset: displayed) }
        return Step(rowID: row, offset: target)
    }
}
