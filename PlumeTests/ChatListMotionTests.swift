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

    // MARK: - Blocks that type themselves out

    @Test func aBlockTheStreamJustOpenedTypes() {
        #expect(
            ChatListMotion.openings(
                previous: ["a/0", "stream/0"],
                current: ["a/0", "stream/0", "stream/1"]
            ) == ["stream/1"]
        )
    }

    /// The case headings hit: one delta carries a whole heading and the start
    /// of the text below it, so the heading is complete the moment it appears
    /// and is never the arriving block.
    @Test func aBlockThatArrivedCompleteStillTypes() {
        #expect(
            ChatListMotion.openings(
                previous: ["stream/0"],
                current: ["stream/0", "stream/1", "stream/2"]
            ) == ["stream/1", "stream/2"]
        )
    }

    @Test func transcriptPiecesNeverType() {
        #expect(
            ChatListMotion.openings(
                previous: ["a/0"],
                current: ["a/0", "a/1", "b/0"]
            ).isEmpty
        )
    }

    /// A tab switched to mid-turn shows the reply that has already arrived
    /// rather than replaying it.
    @Test func theFirstBuildTypesNothing() {
        #expect(ChatListMotion.openings(previous: [], current: ["stream/0", "stream/1"]).isEmpty)
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
