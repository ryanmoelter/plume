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
    /// The jump-back button must not appear at the follow threshold, or it
    /// flickers on and off while the chat is auto-following.
    @Test func detachmentSitsWellPastTheFollowThreshold() {
        #expect(!ChatScrollAnchor.isDetached(distanceFromBottom: 0, wasDetached: false))
        #expect(!ChatScrollAnchor.isDetached(
            distanceFromBottom: ChatScrollAnchor.bottomTolerance + 1,
            wasDetached: false
        ))
        #expect(!ChatScrollAnchor.isDetached(
            distanceFromBottom: ChatScrollAnchor.detachThreshold,
            wasDetached: false
        ))
        #expect(ChatScrollAnchor.isDetached(
            distanceFromBottom: ChatScrollAnchor.detachThreshold + 1,
            wasDetached: false
        ))
    }

    @Test func aDetachedViewNoLongerAutoScrolls() {
        #expect(!ChatScrollAnchor.shouldAutoScroll(
            distanceFromBottom: ChatScrollAnchor.detachThreshold + 1
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
            #expect(!ChatScrollAnchor.isDetached(distanceFromBottom: padding, wasDetached: false))
            #expect(!ChatScrollAnchor.isDetached(distanceFromBottom: padding, wasDetached: true))
        }
    }
}

/// The jump-back flag latches rather than tracking one threshold.
///
/// The band is what keeps the flag from flipping on every scroll frame while
/// the reader rests near it — see `docs/chat-list.md`.
@Suite
struct ChatDetachHysteresisTests {
    @Test func detachingStillTakesTheFullThreshold() {
        #expect(!ChatScrollAnchor.isDetached(
            distanceFromBottom: ChatScrollAnchor.detachThreshold,
            wasDetached: false
        ))
        #expect(ChatScrollAnchor.isDetached(
            distanceFromBottom: ChatScrollAnchor.detachThreshold + 1,
            wasDetached: false
        ))
    }

    @Test func reattachingTakesComingBackPastTheLowerThreshold() {
        #expect(ChatScrollAnchor.isDetached(
            distanceFromBottom: ChatScrollAnchor.reattachThreshold + 1,
            wasDetached: true
        ))
        #expect(!ChatScrollAnchor.isDetached(
            distanceFromBottom: ChatScrollAnchor.reattachThreshold,
            wasDetached: true
        ))
        #expect(!ChatScrollAnchor.isDetached(distanceFromBottom: 0, wasDetached: true))
    }

    /// Inside the band the answer is whatever it already was, so a distance
    /// parked anywhere in there cannot flip the flag. Open at both ends: the
    /// edges themselves belong to the thresholds that cross them.
    @Test func theFlagHoldsItsStateAnywhereInsideTheBand() {
        let band = stride(
            from: ChatScrollAnchor.reattachThreshold + 1,
            through: ChatScrollAnchor.detachThreshold,
            by: 10
        )
        for distance in band {
            #expect(ChatScrollAnchor.isDetached(distanceFromBottom: distance, wasDetached: true))
            #expect(!ChatScrollAnchor.isDetached(distanceFromBottom: distance, wasDetached: false))
        }
    }

    /// A distance wobbling by less than the band's width settles after one
    /// flip, however long it wobbles. Against a single threshold this
    /// alternates forever, which is one rebuild of the list per scroll frame.
    @Test func aDistanceWobblingInsideTheBandFlipsAtMostOnce() {
        let band = ChatScrollAnchor.detachThreshold - ChatScrollAnchor.reattachThreshold
        let high = ChatScrollAnchor.detachThreshold + 1
        let low = high - band + 1
        var state = false
        var flips = 0
        for step in 0..<200 {
            let distance = step.isMultiple(of: 2) ? high : low
            let next = ChatScrollAnchor.isDetached(distanceFromBottom: distance, wasDetached: state)
            if next != state { flips += 1 }
            state = next
        }
        #expect(flips == 1)
        #expect(state)
    }

    /// A full trip away and back crosses two different values, not one. The
    /// distances are literal so that collapsing the band fails this test.
    @Test func aFullTripAwayAndBackLatchesTwice() {
        var state = ChatScrollAnchor.isDetached(distanceFromBottom: 210, wasDetached: false)
        #expect(!state)
        state = ChatScrollAnchor.isDetached(distanceFromBottom: 321, wasDetached: state)
        #expect(state)
        state = ChatScrollAnchor.isDetached(distanceFromBottom: 210, wasDetached: state)
        #expect(state)
        state = ChatScrollAnchor.isDetached(distanceFromBottom: 199, wasDetached: state)
        #expect(!state)
    }

    @Test func theBandSitsBetweenTheFollowThresholdAndTheDetachThreshold() {
        #expect(ChatScrollAnchor.reattachThreshold > ChatScrollAnchor.bottomTolerance)
        #expect(ChatScrollAnchor.reattachThreshold < ChatScrollAnchor.detachThreshold)
    }
}

