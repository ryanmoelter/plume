import SwiftUI

/// What a user message's redo and fork buttons need, threaded to the chat
/// rows through the environment.
///
/// A hosted chat row inherits no environment, so `ChatListItemRoot` has to put
/// this back by hand (`docs/chat-list.md`).
///
/// `onFork` is a closure rather than something the button does itself: forking
/// creates a tab, which needs the `ModelContext` and the `WorkTask` that only
/// `ChatTabView` has. Not `Equatable` for the same reason, so it stays out of
/// `ChatListInputs`.
struct MessageRedoContext {
    var tabID: UUID
    /// The newest user message on screen. The CLI refuses a rewind without
    /// it, since a target chosen against a conversation that has moved on
    /// would cut in the wrong place.
    var lastSeenUserMessageID: String
    /// The parent of each message. A fork cuts at the target's parent rather
    /// than the target, since cutting at the target keeps it and the fork
    /// then opens on two consecutive user turns.
    var parentByMessageID: [String: String]
    /// The messages the transcript actually recorded. The chat also renders
    /// an optimistic first message whose id is Plume's own string rather than
    /// a uuid the CLI has seen, and neither redo nor fork can name that.
    var transcriptMessageIDs: Set<String>
    /// Whether this tab has everything a fork needs: a session id to resume
    /// and a working directory to spawn in. False leaves the fork buttons
    /// disabled rather than letting them open an empty tab that never starts.
    var canFork: Bool
    /// Opens a fork of this conversation cut after the given message uuid.
    var onFork: (String) -> Void
    /// The rows this conversation forked at, and how many messages each one
    /// left on the branch that was abandoned. Rendered as a marker in the
    /// message's footer — a redo or an edit made here at some point, and the
    /// text that was cut is still on disk.
    var abandonedCountByMessageID: [String: Int]

    /// Everything a row actually draws from this, as one comparable value.
    ///
    /// The context holds a closure and so cannot be `Equatable`, but the list
    /// restages a row only when its piece changes — and a fork marker appears
    /// on a transcript change that need not change any piece. Comparing this
    /// is what tells the list to restage anyway.
    var renderedState: RenderedState {
        RenderedState(
            tabID: tabID,
            lastSeenUserMessageID: lastSeenUserMessageID,
            transcriptMessageIDs: transcriptMessageIDs,
            canFork: canFork,
            abandonedCountByMessageID: abandonedCountByMessageID
        )
    }

    struct RenderedState: Equatable {
        var tabID: UUID
        var lastSeenUserMessageID: String
        var transcriptMessageIDs: Set<String>
        var canFork: Bool
        var abandonedCountByMessageID: [String: Int]
    }
}

private struct MessageRedoContextKey: EnvironmentKey {
    static let defaultValue: MessageRedoContext? = nil
}

extension EnvironmentValues {
    /// Set by `ChatTabView` on a live headless tab, and nil everywhere else —
    /// a transcript with no session behind it cannot be rewound.
    var messageRedoContext: MessageRedoContext? {
        get { self[MessageRedoContextKey.self] }
        set { self[MessageRedoContextKey.self] = newValue }
    }
}
