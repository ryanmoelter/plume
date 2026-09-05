import Foundation
import Testing
@testable import Plume

/// A tab whose main agent finished but whose subagents are still running
/// should read `working`, so the sidebar never invites the user back to a
/// task that is still moving. `needsInput` and `error` outrank that.
@MainActor
struct StatusEngineSubagentTests {
    private func engineWithTab() -> (StatusEngine, UUID, UUID) {
        let engine = StatusEngine()
        let (task, tab) = (UUID(), UUID())
        engine.register(tabID: tab, taskID: task)
        return (engine, task, tab)
    }

    @Test(arguments: [
        (TaskStatus.done, TaskStatus.working),
        (.idle, .working),
        (.unset, .working),
        (.working, .working),
        (.needsInput, .needsInput),
        (.error, .error),
        (.interrupted, .interrupted),
    ])
    func workingSubagentsRaiseOnlyTheSettledStatuses(own: TaskStatus, expected: TaskStatus) {
        #expect(StatusEngine.effectiveStatus(own: own, subagentsWorking: true) == expected)
    }

    @Test(arguments: TaskStatus.allCases)
    func idleSubagentsLeaveTheStatusAlone(own: TaskStatus) {
        #expect(StatusEngine.effectiveStatus(own: own, subagentsWorking: false) == own)
    }

    @Test func aFinishedTurnStaysWorkingUntilItsSubagentsStop() {
        let (engine, task, tab) = engineWithTab()

        engine.setSubagentActivity(tabID: tab, working: true)
        engine.setStatus(.done, taskID: task, tabID: tab)

        #expect(engine.status(forTab: tab) == .working)
        #expect(engine.status(forTask: task) == .working)
        #expect(engine.ownStatus(forTab: tab) == .done)

        engine.setSubagentActivity(tabID: tab, working: false)
        #expect(engine.status(forTab: tab) == .done)
        #expect(engine.status(forTask: task) == .done)
    }

    @Test func needsInputSurvivesWorkingSubagents() {
        let (engine, task, tab) = engineWithTab()

        engine.setStatus(.needsInput, taskID: task, tabID: tab)
        engine.setSubagentActivity(tabID: tab, working: true)

        #expect(engine.status(forTab: tab) == .needsInput)
        #expect(engine.status(forTask: task) == .needsInput)
        #expect(engine.tasksNeedingInput == 1)
    }

    @Test func errorSurvivesWorkingSubagents() {
        let (engine, task, tab) = engineWithTab()

        engine.setStatus(.error, taskID: task, tabID: tab)
        engine.setSubagentActivity(tabID: tab, working: true)

        #expect(engine.status(forTab: tab) == .error)
    }

    /// A tab the engine never registered has no task to aggregate into.
    @Test func activityForAnUnknownTabIsDropped() {
        let engine = StatusEngine()
        let tab = UUID()

        engine.setSubagentActivity(tabID: tab, working: true)

        #expect(engine.status(forTab: tab) == .unset)
    }

    @Test func forgettingATabDropsItsSubagentActivity() {
        let (engine, task, tab) = engineWithTab()

        engine.setStatus(.done, taskID: task, tabID: tab)
        engine.setSubagentActivity(tabID: tab, working: true)
        engine.forget(tabID: tab, taskID: task)
        engine.register(tabID: tab, taskID: task, status: .done)

        #expect(engine.status(forTab: tab) == .done)
    }

    // MARK: - Callbacks

    /// `StatusNotifier` hangs off this callback, so a `done` announced while
    /// subagents run would post a "Finished its turn." notification early.
    @Test func theTabCallbackReportsEffectiveStatus() {
        let (engine, task, tab) = engineWithTab()
        var seen: [TaskStatus] = []
        engine.setSubagentActivity(tabID: tab, working: true)
        engine.onTabStatusChanged = { _, _, status in seen.append(status) }

        engine.setStatus(.done, taskID: task, tabID: tab)
        #expect(seen == [])

        engine.setSubagentActivity(tabID: tab, working: false)
        #expect(seen == [.done])
    }

    @Test func theNotifierWouldFireOnceOnTheFinalSettle() {
        let (engine, task, tab) = engineWithTab()
        var bodies: [String] = []
        engine.onTabStatusChanged = { _, _, status in
            if let body = StatusNotifier.body(for: status) { bodies.append(body) }
        }

        engine.setStatus(.working, taskID: task, tabID: tab)
        engine.setSubagentActivity(tabID: tab, working: true)
        engine.setStatus(.done, taskID: task, tabID: tab)
        #expect(bodies.isEmpty)

        engine.setSubagentActivity(tabID: tab, working: false)
        #expect(bodies == ["Finished its turn."])
    }

    /// Subagent activity that changes nothing visible must not re-announce a
    /// status the user has already been told about.
    @Test func activityThatChangesNothingIsSilent() {
        let (engine, task, tab) = engineWithTab()
        engine.setStatus(.needsInput, taskID: task, tabID: tab)

        var seen = 0
        engine.onTabStatusChanged = { _, _, _ in seen += 1 }
        engine.setSubagentActivity(tabID: tab, working: true)
        engine.setSubagentActivity(tabID: tab, working: false)

        #expect(seen == 0)
    }

    @Test func theTaskCallbackReportsEffectiveStatus() {
        let (engine, task, tab) = engineWithTab()
        var seen: [TaskStatus] = []
        engine.onTaskStatusChanged = { _, status in seen.append(status) }

        engine.setSubagentActivity(tabID: tab, working: true)
        engine.setStatus(.done, taskID: task, tabID: tab)
        engine.setSubagentActivity(tabID: tab, working: false)

        #expect(seen == [.working, .done])
    }

    /// One tab's subagents must not hold a sibling tab at working.
    @Test func subagentActivityIsPerTab() {
        let engine = StatusEngine()
        let (task, a, b) = (UUID(), UUID(), UUID())
        engine.setStatus(.done, taskID: task, tabID: a)
        engine.setStatus(.idle, taskID: task, tabID: b)

        engine.setSubagentActivity(tabID: a, working: true)

        #expect(engine.status(forTab: a) == .working)
        #expect(engine.status(forTab: b) == .idle)
    }
}
