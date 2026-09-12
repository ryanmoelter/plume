import Testing
import Foundation
@testable import Plume

@MainActor
struct StatusEngineTests {
    private func event(_ name: String, session: String? = nil) -> HookEvent {
        HookEvent(hookEventName: name, sessionID: session, transcriptPath: nil, cwd: nil)
    }

    @Test func eventsMapToTheDocumentedStatuses() {
        #expect(StatusEngine.status(for: .sessionStart) == .working)
        #expect(StatusEngine.status(for: .userPromptSubmit) == .working)
        #expect(StatusEngine.status(for: .preToolUse) == .working)
        #expect(StatusEngine.status(for: .notification) == .needsTerminalInput)
        #expect(StatusEngine.status(for: .stop) == .awaitingReply)
        #expect(StatusEngine.status(for: .subagentStop) == .awaitingReply)
        #expect(StatusEngine.status(for: .sessionEnd) == .awaitingReply)
    }

    /// `/clear` ends the session while the agent keeps running, so the usual
    /// session-ended-means-the-turn-is-over reading would misreport a live
    /// agent.
    @Test func aClearedSessionEndLeavesTheAgentWorking() {
        let engine = StatusEngine()
        let (task, tab) = (UUID(), UUID())
        engine.apply(event("UserPromptSubmit"), taskID: task, tabID: tab)

        engine.apply(
            HookEvent(hookEventName: "SessionEnd", reason: "clear"),
            taskID: task, tabID: tab
        )

        #expect(engine.status(forTab: tab) == .working)
    }

    @Test func anOrdinarySessionEndStillSettles() {
        let engine = StatusEngine()
        let (task, tab) = (UUID(), UUID())
        engine.apply(event("UserPromptSubmit"), taskID: task, tabID: tab)

        engine.apply(
            HookEvent(hookEventName: "SessionEnd", reason: "other"),
            taskID: task, tabID: tab
        )

        #expect(engine.status(forTab: tab) == .awaitingReply)
    }

    @Test func unknownEventsAreIgnored() {
        #expect(StatusEngine.status(for: .unknown) == nil)

        let engine = StatusEngine()
        let (task, tab) = (UUID(), UUID())
        engine.setStatus(.working, taskID: task, tabID: tab)
        engine.apply(event("SomethingNew"), taskID: task, tabID: tab)

        #expect(engine.status(forTab: tab) == .working)
    }

    @Test func aTurnMovesThroughWorkingThenDone() {
        let engine = StatusEngine()
        let (task, tab) = (UUID(), UUID())

        engine.apply(event("UserPromptSubmit"), taskID: task, tabID: tab)
        #expect(engine.status(forTab: tab) == .working)

        engine.apply(event("PreToolUse"), taskID: task, tabID: tab)
        #expect(engine.status(forTab: tab) == .working)

        engine.apply(event("Stop"), taskID: task, tabID: tab)
        #expect(engine.status(forTab: tab) == .awaitingReply)
    }

    @Test func permissionPromptNeedsInputThenResumesWorking() {
        let engine = StatusEngine()
        let (task, tab) = (UUID(), UUID())

        engine.apply(event("PreToolUse"), taskID: task, tabID: tab)
        engine.apply(event("Notification"), taskID: task, tabID: tab)
        #expect(engine.status(forTab: tab) == .needsTerminalInput)

        engine.apply(event("PreToolUse"), taskID: task, tabID: tab)
        #expect(engine.status(forTab: tab) == .working)
    }

    @Test func taskStatusTakesTheHighestPriorityTab() {
        let engine = StatusEngine()
        let task = UUID()
        let (a, b, c) = (UUID(), UUID(), UUID())

        engine.setStatus(.awaitingReply, taskID: task, tabID: a)
        engine.setStatus(.working, taskID: task, tabID: b)
        engine.setStatus(.permissionNeeded, taskID: task, tabID: c)

        #expect(engine.status(forTask: task) == .permissionNeeded)

        engine.setStatus(.awaitingReply, taskID: task, tabID: c)
        #expect(engine.status(forTask: task) == .working)
    }

    @Test func tasksAreIndependent() {
        let engine = StatusEngine()
        let (taskA, taskB) = (UUID(), UUID())

        engine.setStatus(.permissionNeeded, taskID: taskA, tabID: UUID())
        engine.setStatus(.awaitingReply, taskID: taskB, tabID: UUID())

        #expect(engine.status(forTask: taskA) == .permissionNeeded)
        #expect(engine.status(forTask: taskB) == .awaitingReply)
    }

    @Test func surfaceExitWhileAliveIsAnError() {
        let engine = StatusEngine()
        let (task, tab) = (UUID(), UUID())

        engine.apply(event("PreToolUse"), taskID: task, tabID: tab)
        engine.handleSurfaceExit(taskID: task, tabID: tab, processAlive: true)

        #expect(engine.status(forTab: tab) == .error)
    }

    @Test func cleanSurfaceExitIsIdle() {
        let engine = StatusEngine()
        let (task, tab) = (UUID(), UUID())

        engine.apply(event("Stop"), taskID: task, tabID: tab)
        engine.handleSurfaceExit(taskID: task, tabID: tab, processAlive: false)

        #expect(engine.status(forTab: tab) == .awaitingReply)
    }

    @Test func taskStatusChangesAreReportedOnce() {
        let engine = StatusEngine()
        let (task, tab) = (UUID(), UUID())
        var changes: [TaskStatus] = []
        engine.onTaskStatusChanged = { _, status in changes.append(status) }

        engine.apply(event("UserPromptSubmit"), taskID: task, tabID: tab)
        engine.apply(event("PreToolUse"), taskID: task, tabID: tab) // still working
        engine.apply(event("Stop"), taskID: task, tabID: tab)

        #expect(changes == [.working, .awaitingReply])
    }

    @Test func needsInputCountTracksTasksNotTabs() {
        let engine = StatusEngine()
        let task = UUID()

        engine.setStatus(.permissionNeeded, taskID: task, tabID: UUID())
        engine.setStatus(.permissionNeeded, taskID: task, tabID: UUID())
        #expect(engine.tasksNeedingInput == 1)

        engine.setStatus(.permissionNeeded, taskID: UUID(), tabID: UUID())
        #expect(engine.tasksNeedingInput == 2)
    }

    @Test func forgettingATabRemovesItFromItsTask() {
        let engine = StatusEngine()
        let (task, tab) = (UUID(), UUID())

        engine.setStatus(.permissionNeeded, taskID: task, tabID: tab)
        engine.forget(tabID: tab, taskID: task)

        #expect(engine.status(forTask: task) == .notStarted)
        #expect(engine.tasksNeedingInput == 0)
    }

    @Test func registeringATabDoesNotOverwriteAKnownStatus() {
        let engine = StatusEngine()
        let (task, tab) = (UUID(), UUID())

        engine.setStatus(.working, taskID: task, tabID: tab)
        engine.register(tabID: tab, taskID: task, status: .awaitingReply)

        #expect(engine.status(forTab: tab) == .working)
    }
}
