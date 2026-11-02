import Foundation

/// Which way a composer's slash and mention lists open from the field.
enum ComposerSuggestionDirection {
    /// Over the field, for a composer pinned to the bottom of its pane.
    case up
    /// Under the controls, for a composer anchored to the top.
    case down
}

/// Where a composer sends when its tab has no agent to send to and is never
/// going to have one: Home's, whose message starts a new task instead.
///
/// The composer still keeps its draft, mentions and launch choices under its
/// tab's ID. Features that need a running session or a task of their own —
/// command mode, Plume's `/rc` and `/btw`, Send Now — stay off.
struct ComposerHandOff {
    nonisolated struct Message: Equatable {
        /// The draft as typed, before mentions are expanded into links.
        let typedText: String
        let blocks: [UserContentBlock]
    }

    var placeholder: String
    /// False while there is nowhere to send to yet.
    var isReady: Bool
    /// False when the message was not taken, so the composer puts it back.
    let send: (Message) async -> Bool
}
