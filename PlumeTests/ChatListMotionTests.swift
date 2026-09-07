import Foundation
import Testing
@testable import Plume

/// Which pieces grow into place when the chat list rebuilds: the ones that
/// were not there before, and none at all on a first build or while the
/// streaming overlay is churning.
struct ChatListMotionTests {
    private func arrivals(
        previous: [String],
        current: [String],
        streamingChanged: Bool = false
    ) -> Set<String> {
        ChatListMotion.arrivals(
            previous: previous,
            current: current,
            streamingChanged: streamingChanged
        )
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

    @Test func aChangedStreamingOverlayGrowsNothing() {
        #expect(
            arrivals(
                previous: ["a", "stream/live"],
                current: ["a", "stream/0", "stream/live"],
                streamingChanged: true
            ).isEmpty
        )
    }
}
