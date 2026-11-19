import Foundation
import Testing
@testable import Plume

/// Which pieces grow into place when the chat list rebuilds: the ones that
/// were not there before, and none at all on a first build; and which
/// height changes ease, which is any of a point or more.
@MainActor
struct ChatListMotionTests {
    private func arrivals(previous: [String], current: [String]) -> Set<String> {
        ChatListMotion.arrivals(previous: previous, current: current)
    }

    @Test func namesOnlyTheIDsThatWereNotThereBefore() {
        #expect(arrivals(previous: ["a", "b"], current: ["a", "b", "c"]) == ["c"])
    }

    @Test func aPieceLeavingBringsNoArrivals() {
        #expect(arrivals(previous: ["a", "b", "c"], current: ["a", "c"]).isEmpty)
    }

    @Test func reorderingAloneBringsNoArrivals() {
        #expect(arrivals(previous: ["a", "b"], current: ["b", "a"]).isEmpty)
    }

    @Test func aReplacedPieceCountsAsAnArrival() {
        #expect(arrivals(previous: ["a", "b"], current: ["a", "c"]) == ["c"])
    }

    @Test func theFirstBuildGrowsNothing() {
        #expect(arrivals(previous: [], current: ["a", "b", "c"]).isEmpty)
    }

    @Test func aChangeOfAPointOrMoreEases() {
        #expect(ChatListMotion.easesHeightChange(from: 100, to: 101))
        #expect(ChatListMotion.easesHeightChange(from: 100, to: 40))
    }

    @Test func aChangeUnderAPointSnaps() {
        #expect(!ChatListMotion.easesHeightChange(from: 100, to: 100.4))
        #expect(!ChatListMotion.easesHeightChange(from: 100, to: 99.01))
        #expect(!ChatListMotion.easesHeightChange(from: 100, to: 100))
    }
}
