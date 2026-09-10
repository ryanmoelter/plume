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
        (TaskStatus.awaitingReply, TaskStatus.working),
        (.awaitingReply, .working),
        (.notStarted, .working),
        (.working, .working),
        (.permissionNeeded, .permissionNeeded),
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
        engine.setStatus(.awaitingReply, taskID: task, tabID: tab)

        #expect(engine.status(forTab: tab) == .working)
        #expect(engine.status(forTask: task) == .working)
        #expect(engine.ownStatus(forTab: tab) == .awaitingReply)

        engine.setSubagentActivity(tabID: tab, working: false)
        #expect(engine.status(forTab: tab) == .awaitingReply)
        #expect(engine.status(forTask: task) == .awaitingReply)
    }

    @Test func needsInputSurvivesWorkingSubagents() {
        let (engine, task, tab) = engineWithTab()

        engine.setStatus(.permissionNeeded, taskID: task, tabID: tab)
        engine.setSubagentActivity(tabID: tab, working: true)

        #expect(engine.status(forTab: tab) == .permissionNeeded)
        #expect(engine.status(forTask: task) == .permissionNeeded)
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

        #expect(engine.status(forTab: tab) == .notStarted)
    }

    @Test func forgettingATabDropsItsSubagentActivity() {
        let (engine, task, tab) = engineWithTab()

        engine.setStatus(.awaitingReply, taskID: task, tabID: tab)
        engine.setSubagentActivity(tabID: tab, working: true)
        engine.forget(tabID: tab, taskID: task)
        engine.register(tabID: tab, taskID: task, status: .awaitingReply)

        #expect(engine.status(forTab: tab) == .awaitingReply)
    }

    // MARK: - Callbacks

    /// `StatusNotifier` hangs off this callback, so a `done` announced while
    /// subagents run would post a "Finished its turn." notification early.
    @Test func theTabCallbackReportsEffectiveStatus() {
        let (engine, task, tab) = engineWithTab()
        var seen: [TaskStatus] = []
        engine.setSubagentActivity(tabID: tab, working: true)
        engine.onTabStatusChanged = { _, _, status in seen.append(status) }

        engine.setStatus(.awaitingReply, taskID: task, tabID: tab)
        #expect(seen == [])

        engine.setSubagentActivity(tabID: tab, working: false)
        #expect(seen == [.awaitingReply])
    }

    @Test func theNotifierWouldFireOnceOnTheFinalSettle() {
        let (engine, task, tab) = engineWithTab()
        var bodies: [String] = []
        engine.onTabStatusChanged = { _, _, status in
            if let body = StatusNotifier.body(for: status, notifiesOnTurnEnd: true) { bodies.append(body) }
        }

        engine.setStatus(.working, taskID: task, tabID: tab)
        engine.setSubagentActivity(tabID: tab, working: true)
        engine.setStatus(.awaitingReply, taskID: task, tabID: tab)
        #expect(bodies.isEmpty)

        engine.setSubagentActivity(tabID: tab, working: false)
        #expect(bodies == ["It's your turn."])
    }

    /// Subagent activity that changes nothing visible must not re-announce a
    /// status the user has already been told about.
    @Test func activityThatChangesNothingIsSilent() {
        let (engine, task, tab) = engineWithTab()
        engine.setStatus(.permissionNeeded, taskID: task, tabID: tab)

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
        engine.setStatus(.awaitingReply, taskID: task, tabID: tab)
        engine.setSubagentActivity(tabID: tab, working: false)

        #expect(seen == [.working, .awaitingReply])
    }

    /// One tab's subagents must not hold a sibling tab at working.
    @Test func subagentActivityIsPerTab() {
        let engine = StatusEngine()
        let (task, a, b) = (UUID(), UUID(), UUID())
        engine.setStatus(.awaitingReply, taskID: task, tabID: a)
        engine.setStatus(.awaitingReply, taskID: task, tabID: b)

        engine.setSubagentActivity(tabID: a, working: true)

        #expect(engine.status(forTab: a) == .working)
        #expect(engine.status(forTab: b) == .awaitingReply)
    }
}
