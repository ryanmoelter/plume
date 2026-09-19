import Foundation
import Testing
@testable import Plume

@MainActor
struct CommandModeRunsTests {
    @Test func aFinishedRunDeliversItsResultAndLeaves() async {
        let runs = CommandModeRuns()
        let tabID = UUID()
        let result = await withCheckedContinuation { continuation in
            runs.start("echo hi", in: nil, tabID: tabID) { continuation.resume(returning: $0) }
            #expect(runs.runs(forTab: tabID).map(\.command) == ["echo hi"])
        }
        #expect(result.stdout == "hi")
        #expect(runs.runs(forTab: tabID).isEmpty)
    }

    @Test func aCancelledRunSendsNothing() async throws {
        let runs = CommandModeRuns()
        let tabID = UUID()
        var delivered = false
        runs.start("sleep 60", in: nil, tabID: tabID) { _ in delivered = true }
        let run = try #require(runs.runs(forTab: tabID).first)

        runs.cancel(run.id, tabID: tabID)
        #expect(runs.runs(forTab: tabID).isEmpty)
        // Long enough for the killed command's result to come back.
        try await Task.sleep(for: .seconds(1))
        #expect(!delivered)
    }

    @Test func forgettingATabCancelsItsRuns() async throws {
        let runs = CommandModeRuns()
        let tabID = UUID()
        var delivered = false
        runs.start("sleep 60", in: nil, tabID: tabID) { _ in delivered = true }

        runs.forget(tabID: tabID)
        #expect(runs.runs(forTab: tabID).isEmpty)
        try await Task.sleep(for: .seconds(1))
        #expect(!delivered)
    }
}
