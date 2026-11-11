import Foundation
import Testing
@testable import Plume

struct ReviewChangeMagnitudeTests {
    @Test(arguments: [
        (0, 0), (1, 1), (7, 1), (9, 1), (10, 2), (99, 2), (100, 3), (250, 3), (1_000, 4), (4_000, 4), (10_000, 5),
    ])
    func oneBoxPerOrderOfMagnitudeReached(lines: Int, boxes: Int) {
        #expect(ReviewChangeMagnitude.boxCount(changedLines: lines) == boxes)
    }

    @Test func theHundredBoxIsTheBaseSizeAndEachBoxGrowsByTheRatio() {
        let base = ReviewChangeMagnitude.baseSize
        let growth = ReviewChangeMagnitude.growth
        #expect(ReviewChangeMagnitude.side(ofBox: 2) == base)
        #expect(abs(ReviewChangeMagnitude.side(ofBox: 1) - base / growth) < 0.0001)
        #expect(abs(ReviewChangeMagnitude.side(ofBox: 0) - base / (growth * growth)) < 0.0001)
        #expect(abs(ReviewChangeMagnitude.side(ofBox: 3) - base * growth) < 0.0001)
    }

    @Test func theTintFollowsTheAddedToDeletedRatio() {
        #expect(ReviewChangeMagnitude.tint(added: 5, removed: 0) == .added)
        #expect(ReviewChangeMagnitude.tint(added: 20, removed: 10) == .added)
        #expect(ReviewChangeMagnitude.tint(added: 10, removed: 10) == .modified)
        #expect(ReviewChangeMagnitude.tint(added: 0, removed: 3) == .deleted)
    }
}
