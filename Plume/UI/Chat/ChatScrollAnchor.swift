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

    /// How far the user must be from the bottom before a jump-back button is
    /// worth offering. Well past `bottomTolerance`, so the button does not
    /// flicker in and out around the follow threshold, and past a screenful of
    /// nudge-scrolling that the user will scroll back by hand anyway.
    static let detachThreshold: CGFloat = 320

    /// How close the reader has to come back before the flag clears again.
    ///
    /// Two thresholds rather than one, because a single one chatters: a
    /// distance resting near it flips the flag on every scroll frame, and
    /// whatever renders from the flag then relayouts on every frame too.
    /// `docs/chat-list-hang.md` records that as hypothesis 4. The band is
    /// wider than any one momentum frame's travel, and still far enough out
    /// that clearing the flag means the reader really is back at the bottom.
    static let reattachThreshold: CGFloat = 200

    /// Whether the reader has scrolled far enough from the bottom to want a
    /// way back down, given whether they already had one.
    ///
    /// Latches: past `detachThreshold` it turns on, back inside
    /// `reattachThreshold` it turns off, and between the two it holds. So the
    /// answer depends on the current state as well as the distance.
    static func isDetached(distanceFromBottom: CGFloat, wasDetached: Bool) -> Bool {
        if wasDetached {
            distanceFromBottom > reattachThreshold
        } else {
            distanceFromBottom > detachThreshold
        }
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
    /// Zero while the list is offscreen, which is how a hidden tab is told
    /// apart from a visible one scrolled to its top.
    var viewportHeight: CGFloat = 0
    var visibleMinY: CGFloat = 0
}
