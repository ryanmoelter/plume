import Foundation
import Testing
@testable import Plume

@MainActor
struct CommandModeAwakeTests {
    @Test func runningCommandHoldsUntilItsProcessFinishesNotUntilItsChipDisappears() async {
        let runs = CommandModeRuns()
        let tab = UUID(), task = UUID()
        await withCheckedContinuation { continuation in
            runs.start("printf done", in: nil, tabID: tab, taskID: task) { _, _ in
                continuation.resume()
            }
            #expect(runs.activeCommands.count == 1)
            #expect(runs.activeCommands.first?.taskID == task)
        }
        #expect(!runs.runs(forTab: tab).isEmpty)
        #expect(runs.activeCommands.isEmpty)
        runs.forget(tabID: tab)
    }

    @Test func aLocalCommandCountsEvenBeforeTheAgentStartsAndCancelReleasesIt() {
        let runs = CommandModeRuns()
        let tab = UUID(), task = UUID(), destination = UUID()
        let id = runs.start("sleep 60", in: nil, tabID: tab, taskID: task) { _, _ in }
        runs.reparent(tabID: tab, taskID: destination)
        #expect(runs.activeCommands.first?.taskID == destination)
        let reasons = KeepAwakeCoordinator.deriveReasons(
            activeTabs: [], remoteControlledTabs: [],
            commandTabs: [(destination, tab, "sleep 60")]
        )
        #expect(reasons == [.init(taskID: destination, tabID: tab,
                                kind: .backgroundTask(.backgroundCommand, description: "sleep 60"))])
        runs.cancel(id, tabID: tab)
        #expect(runs.activeCommands.isEmpty)
    }

    @Test func localAndAgentBackgroundCommandsProduceOneReasonPerTab() {
        let tab = UUID(), task = UUID()
        let reasons = KeepAwakeCoordinator.deriveReasons(
            activeTabs: [], remoteControlledTabs: [],
            backgroundTaskTabs: [(task, tab, .backgroundCommand, "agent build")],
            commandTabs: [(task, tab, "local test"), (task, tab, "local lint")]
        )
        #expect(reasons.count == 1)
    }
}
