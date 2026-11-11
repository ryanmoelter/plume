import Foundation
import Testing
@testable import Plume

/// `CheckContext.latestRuns` keeps one context per name: the newest by start
/// time, a queued run over any started one, and the later in the list on a
/// tie. Names keep the position they first appeared at.
struct CheckLatestRunsTests {
    private func at(_ minute: Int) -> Date {
        Date(timeIntervalSince1970: TimeInterval(minute * 60))
    }

    @Test func distinctNamesPassThroughInOrder() {
        let contexts = [
            CheckContext(name: "lint", status: "SUCCESS", startedAt: at(2)),
            CheckContext(name: "build", status: "FAILURE", startedAt: at(1)),
        ]
        #expect(CheckContext.latestRuns(contexts) == contexts)
    }

    @Test func theLaterStartWins() {
        let newer = CheckContext(name: "build", status: "SUCCESS", startedAt: at(5))
        let older = CheckContext(name: "build", status: "FAILURE", startedAt: at(1))
        #expect(CheckContext.latestRuns([newer, older]) == [newer])
        #expect(CheckContext.latestRuns([older, newer]) == [newer])
    }

    @Test func aQueuedRerunBeatsAFinishedRun() {
        let finished = CheckContext(name: "build", status: "FAILURE", startedAt: at(5))
        let queued = CheckContext(name: "build", status: "QUEUED")
        #expect(CheckContext.latestRuns([queued, finished]) == [queued])
    }

    @Test func withoutTimesTheLastListedWins() {
        let contexts = [
            CheckContext(name: "label", status: "SKIPPED"),
            CheckContext(name: "lint", status: "SUCCESS"),
            CheckContext(name: "label", status: "SUCCESS"),
        ]
        #expect(CheckContext.latestRuns(contexts) == [
            CheckContext(name: "label", status: "SUCCESS"),
            CheckContext(name: "lint", status: "SUCCESS"),
        ])
    }

    /// 1_794_304_800 is 2026-11-10T10:00:00Z.
    @Test func aStatusContextTimestampParses() {
        let context = CheckContext(context: "ci/lint", state: "SUCCESS", startedAt: "2026-11-10T10:00:00Z")
        #expect(context.startedAt == Date(timeIntervalSince1970: 1_794_304_800))
    }

    @Test func noContextsStayEmpty() {
        #expect(CheckContext.latestRuns([]).isEmpty)
    }
}
