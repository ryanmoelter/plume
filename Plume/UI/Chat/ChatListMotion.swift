import Foundation

/// Which pieces the chat list grows into place rather than drawing at size,
/// and which height changes it eases rather than snaps.
///
/// A piece that has just arrived starts at zero height, and that growth is
/// what pushes the conversation up.
enum ChatListMotion {
    /// The ids in `current` that `previous` did not have.
    ///
    /// Empty on the first build, which has no previous ids: a tab opening
    /// should show its conversation rather than play it.
    static func arrivals(previous: [String], current: [String]) -> Set<String> {
        guard !previous.isEmpty else { return [] }
        return Set(current).subtracting(previous)
    }

    /// A change under a point is invisible, but easing it would re-lay out
    /// the list on every frame of the ease, and realizing a row often
    /// measures it a fraction of a point off its last measurement.
    static func easesHeightChange(from: CGFloat, to: CGFloat) -> Bool {
        abs(to - from) >= 1
    }
}
