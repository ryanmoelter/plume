import Foundation

/// The geometry of the floating composer panel: how a box inside it is
/// rounded.
///
/// One radius decides the rest, so the panel and the composer box inside it
/// stay a family however the panel's own radius moves.
enum ComposerPanelMetrics {
    /// The radius that keeps an even gap around the corner of a box inset by
    /// `inset` inside a container rounded to `outer`.
    static func concentricRadius(outer: CGFloat, inset: CGFloat) -> CGFloat {
        max(outer - inset, 0)
    }
}
