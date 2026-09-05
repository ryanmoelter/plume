import Foundation

/// The geometry of the floating composer panel: how a box inside it is
/// rounded, and how a card tucked behind it is sized.
///
/// One radius decides the rest, so the panel, the composer box inside it and
/// the plan bar behind it stay a family however the panel's own radius moves.
enum ComposerPanelMetrics {
    /// The radius that keeps an even gap around the corner of a box inset by
    /// `inset` inside a container rounded to `outer`.
    static func concentricRadius(outer: CGFloat, inset: CGFloat) -> CGFloat {
        max(outer - inset, 0)
    }

    /// How far a tucked card steps in from the panel in front of it.
    ///
    /// The card squares off the edge it meets, so its bottom corners have to
    /// land on the panel's straight top edge — anything narrower than the
    /// radius leaves them poking out of the rounding.
    static func tuckedInset(panelCornerRadius: CGFloat) -> CGFloat {
        max(panelCornerRadius, 0)
    }
}
