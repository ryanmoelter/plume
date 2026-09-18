import Foundation

/// Which pieces the chat list grows into place rather than drawing at size.
///
/// A piece that has just arrived starts at zero height, and that growth is
/// what pushes the conversation up.
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

    /// The blocks the stream has just opened, which type themselves out.
    ///
    /// Separate from `arrivals`, which a changed overlay suppresses: a block
    /// opening *is* the overlay changing, so the two signals cannot share a
    /// rule. Empty on the first build, so a tab switched to mid-turn shows
    /// the reply that has already arrived rather than replaying it.
    ///
    /// This is what lets a block that was complete the moment it appeared
    /// type at all. A heading ends at a single newline rather than a blank
    /// line, so one delta routinely carries a whole heading and the start of
    /// what follows it; the heading is then never the arriving block, and
    /// without this it would snap to full while everything around it typed.
    static func openings(previous: [String], current: [String]) -> Set<String> {
        guard !previous.isEmpty else { return [] }
        return Set(current.filter { $0.hasPrefix(streamIDPrefix) })
            .subtracting(previous)
    }

    /// Matches the ids `ChatPieceSplitter` gives the turn in flight.
    private static let streamIDPrefix = "stream/"
}
