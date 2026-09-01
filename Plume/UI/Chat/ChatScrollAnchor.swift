import Foundation

/// Pure decisions for the chat scroll view, kept out of `ChatTabView` so they
/// stay testable without SwiftUI.
enum ChatScrollAnchor {
    /// Anything within this many points of the bottom still counts as "at the
    /// bottom" — close enough that a new message shouldn't feel like it broke
    /// the user's scroll position.
    static let bottomTolerance: CGFloat = 40

    /// Whether a new message should auto-scroll the view, given how far the
    /// user's last scroll position sat from the bottom. Once they scroll away
    /// from the bottom, new messages stop chasing them until they scroll back.
    static func shouldAutoScroll(distanceFromBottom: CGFloat) -> Bool {
        distanceFromBottom <= bottomTolerance
    }

    /// The last message is the only one eligible for the in-progress /
    /// needs-input treatment — an older message can't be "in progress".
    static func isEligibleForLiveStatus(messageID: String, lastMessageID: String?) -> Bool {
        messageID == lastMessageID
    }
}
