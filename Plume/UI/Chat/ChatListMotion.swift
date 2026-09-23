import Foundation

/// Which pieces the chat list grows into place rather than drawing at size.
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
}
