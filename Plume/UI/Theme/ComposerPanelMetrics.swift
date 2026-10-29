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

    /// How far a suggestion panel's rows sit inside its box.
    static let suggestionRowInset: CGFloat = 4

    /// What a suggestion row's text pays inside the box before it starts,
    /// which is also how far the box steps out past the composer's content.
    static func suggestionTextInset(contentInset: CGFloat) -> CGFloat {
        suggestionRowInset + contentInset
    }
}
