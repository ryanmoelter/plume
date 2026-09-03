import Foundation
import Testing
@testable import Plume

struct ChatScrollAnchorTests {
    @Test func autoScrollsWhenAtTheBottom() {
        #expect(ChatScrollAnchor.shouldAutoScroll(distanceFromBottom: 0))
        #expect(ChatScrollAnchor.shouldAutoScroll(distanceFromBottom: 40))
    }

    @Test func stopsAutoScrollingOnceTheUserScrollsAway() {
        #expect(!ChatScrollAnchor.shouldAutoScroll(distanceFromBottom: 41))
        #expect(!ChatScrollAnchor.shouldAutoScroll(distanceFromBottom: 500))
    }

    @Test func onlyTheLastMessageIsEligibleForLiveStatus() {
        #expect(ChatScrollAnchor.isEligibleForLiveStatus(messageID: "b", lastMessageID: "b"))
        #expect(!ChatScrollAnchor.isEligibleForLiveStatus(messageID: "a", lastMessageID: "b"))
    }

    @Test func noMessageIsEligibleWithoutALastMessageID() {
        #expect(!ChatScrollAnchor.isEligibleForLiveStatus(messageID: "a", lastMessageID: nil))
    }
}

@Suite
struct ChatScrollGrowthTests {
    @Test func onlyANonGrowthChangeReflectsTheUserScroll() {
        #expect(ChatScrollAnchor.reflectsUserScroll(
            previousContentHeight: 900,
            newContentHeight: 900
        ))
        #expect(!ChatScrollAnchor.reflectsUserScroll(
            previousContentHeight: 900,
            newContentHeight: 1200
        ))
    }

    /// The jump-back button must not appear at the follow threshold, or it
    /// flickers on and off while the chat is auto-following.
    @Test func detachmentSitsWellPastTheFollowThreshold() {
        #expect(!ChatScrollAnchor.isDetached(distanceFromBottom: 0))
        #expect(!ChatScrollAnchor.isDetached(distanceFromBottom: ChatScrollAnchor.bottomTolerance + 1))
        #expect(!ChatScrollAnchor.isDetached(distanceFromBottom: ChatScrollAnchor.detachedThreshold))
        #expect(ChatScrollAnchor.isDetached(distanceFromBottom: ChatScrollAnchor.detachedThreshold + 1))
    }

    @Test func aDetachedViewNoLongerAutoScrolls() {
        #expect(!ChatScrollAnchor.shouldAutoScroll(
            distanceFromBottom: ChatScrollAnchor.detachedThreshold + 1
        ))
    }

    /// The anchor must be the last thing in the scroll content, below the
    /// list's bottom padding. Above it, a settled reply comes to rest a whole
    /// padding from the bottom — more than `bottomTolerance` at any sane font
    /// size — so following silently stops, and stays short of
    /// `detachedThreshold`, so the jump-back button never offers a way out.
    @Test func aRestingPaddingsDistanceWouldStopTheChatFollowing() {
        for bodySize in [11.0, 13.0, 14.0, 18.0] as [CGFloat] {
            let padding = Dimensions(bodySize: bodySize).listBottomPadding
            #expect(!ChatScrollAnchor.shouldAutoScroll(distanceFromBottom: padding))
            #expect(!ChatScrollAnchor.isDetached(distanceFromBottom: padding))
        }
    }
}
