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
