import Foundation

/// Which pieces the chat list grows into place rather than drawing at size.
///
/// A piece that has just arrived starts at zero height, and that growth is
/// what pushes the conversation up — `AnimatedHeight` runs it, so the list
/// never wraps its `ForEach` in an animated transaction. `docs/chat-list-hang.md`
/// is why that distinction is worth keeping.
enum ChatListMotion {
    /// The ids in `current` that `previous` did not have.
    ///
    /// Empty in the two cases where growing every new piece would be wrong:
    ///
    /// - The first build, which has no previous ids. A tab opening should
    ///   show its conversation rather than play it.
    /// - A rebuild that carries a changed streaming overlay. The overlay
    ///   settles a piece every time a paragraph finishes and replaces all of
    ///   them with the transcript's own at the end of a turn, so growing
    ///   those would fight the character reveal and re-animate text the
    ///   reader has already read.
    static func arrivals(
        previous: [String],
        current: [String],
        streamingChanged: Bool
    ) -> Set<String> {
        guard !previous.isEmpty, !streamingChanged else { return [] }
        return Set(current).subtracting(previous)
    }
}
