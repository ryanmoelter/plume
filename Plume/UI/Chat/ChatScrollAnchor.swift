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

    /// Whether growing content should pull the view down with it.
    ///
    /// An agent's reply arrives as repeated growth of the *same* message
    /// rather than as new ones, so following it means reacting to the content
    /// getting taller. The distance has to be the one measured before the
    /// growth: afterwards the new content is already below the viewport, which
    /// reads as "the user has scrolled away" no matter where they were.
    static func shouldFollowGrowth(
        previousDistanceFromBottom: CGFloat,
        previousContentHeight: CGFloat,
        newContentHeight: CGFloat
    ) -> Bool {
        guard newContentHeight > previousContentHeight else { return false }
        // A first layout reports growth from zero with no scroll position to
        // preserve; `onAppear` already pins that case to the bottom.
        guard previousContentHeight > 0 else { return false }
        return shouldAutoScroll(distanceFromBottom: previousDistanceFromBottom)
    }

    /// Whether a geometry change reflects where the *user* put the view,
    /// rather than content growing underneath it.
    ///
    /// Only the former may be recorded as the scroll position. Growth pushes
    /// the bottom away from the viewport, so recording its distance reads as
    /// "the user scrolled away" and stops the chat following new messages.
    static func reflectsUserScroll(
        previousContentHeight: CGFloat,
        newContentHeight: CGFloat
    ) -> Bool {
        previousContentHeight == newContentHeight
    }

    /// The last message is the only one eligible for the in-progress /
    /// needs-input treatment — an older message can't be "in progress".
    static func isEligibleForLiveStatus(messageID: String, lastMessageID: String?) -> Bool {
        messageID == lastMessageID
    }
}

/// The two scroll-geometry numbers the chat reacts to, paired so a single
/// `onScrollGeometryChange` reports both and can compare them against the
/// previous pair.
struct ChatScrollGeometry: Equatable {
    var distanceFromBottom: CGFloat
    var contentHeight: CGFloat
}
