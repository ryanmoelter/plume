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
    @Test func followsGrowthWhenParkedAtTheBottom() {
        #expect(ChatScrollAnchor.shouldFollowGrowth(
            previousDistanceFromBottom: 0,
            previousContentHeight: 400,
            newContentHeight: 460
        ))
    }

    @Test func leavesTheViewAloneWhenScrolledAway() {
        #expect(!ChatScrollAnchor.shouldFollowGrowth(
            previousDistanceFromBottom: 900,
            previousContentHeight: 400,
            newContentHeight: 460
        ))
    }

    @Test func ignoresAChangeThatIsNotGrowth() {
        #expect(!ChatScrollAnchor.shouldFollowGrowth(
            previousDistanceFromBottom: 0,
            previousContentHeight: 400,
            newContentHeight: 400
        ))
        #expect(!ChatScrollAnchor.shouldFollowGrowth(
            previousDistanceFromBottom: 0,
            previousContentHeight: 400,
            newContentHeight: 320
        ))
    }

    @Test func ignoresTheFirstLayout() {
        #expect(!ChatScrollAnchor.shouldFollowGrowth(
            previousDistanceFromBottom: 0,
            previousContentHeight: 0,
            newContentHeight: 400
        ))
    }

    /// Within the tolerance still counts as parked at the bottom, so a reply
    /// that lands a few points off does not strand the reader.
    @Test func followsGrowthWithinTheTolerance() {
        #expect(ChatScrollAnchor.shouldFollowGrowth(
            previousDistanceFromBottom: ChatScrollAnchor.bottomTolerance - 1,
            previousContentHeight: 400,
            newContentHeight: 460
        ))
    }

    /// The regression this guards: recording a growth-driven geometry change
    /// as the scroll position makes the chat stop following new messages,
    /// because growth always reports a large distance from the bottom.
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
}
