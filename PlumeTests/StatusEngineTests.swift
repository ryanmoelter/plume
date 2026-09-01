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
        #expect(StatusEngine.status(for: .notification) == .needsInput)
        #expect(StatusEngine.status(for: .stop) == .done)
        #expect(StatusEngine.status(for: .subagentStop) == .done)
        #expect(StatusEngine.status(for: .sessionEnd) == .idle)
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
        #expect(engine.status(forTab: tab) == .done)
    }

    @Test func permissionPromptNeedsInputThenResumesWorking() {
        let engine = StatusEngine()
        let (task, tab) = (UUID(), UUID())

        engine.apply(event("PreToolUse"), taskID: task, tabID: tab)
        engine.apply(event("Notification"), taskID: task, tabID: tab)
        #expect(engine.status(forTab: tab) == .needsInput)

        engine.apply(event("PreToolUse"), taskID: task, tabID: tab)
        #expect(engine.status(forTab: tab) == .working)
    }

    @Test func taskStatusTakesTheHighestPriorityTab() {
        let engine = StatusEngine()
        let task = UUID()
        let (a, b, c) = (UUID(), UUID(), UUID())

        engine.setStatus(.done, taskID: task, tabID: a)
        engine.setStatus(.working, taskID: task, tabID: b)
        engine.setStatus(.needsInput, taskID: task, tabID: c)

        #expect(engine.status(forTask: task) == .needsInput)

        engine.setStatus(.done, taskID: task, tabID: c)
        #expect(engine.status(forTask: task) == .working)
    }

    @Test func tasksAreIndependent() {
        let engine = StatusEngine()
        let (taskA, taskB) = (UUID(), UUID())

        engine.setStatus(.needsInput, taskID: taskA, tabID: UUID())
        engine.setStatus(.idle, taskID: taskB, tabID: UUID())

        #expect(engine.status(forTask: taskA) == .needsInput)
        #expect(engine.status(forTask: taskB) == .idle)
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

        #expect(engine.status(forTab: tab) == .idle)
    }

    @Test func taskStatusChangesAreReportedOnce() {
        let engine = StatusEngine()
        let (task, tab) = (UUID(), UUID())
        var changes: [TaskStatus] = []
        engine.onTaskStatusChanged = { _, status in changes.append(status) }

        engine.apply(event("UserPromptSubmit"), taskID: task, tabID: tab)
        engine.apply(event("PreToolUse"), taskID: task, tabID: tab) // still working
        engine.apply(event("Stop"), taskID: task, tabID: tab)

        #expect(changes == [.working, .done])
    }

    @Test func needsInputCountTracksTasksNotTabs() {
        let engine = StatusEngine()
        let task = UUID()

        engine.setStatus(.needsInput, taskID: task, tabID: UUID())
        engine.setStatus(.needsInput, taskID: task, tabID: UUID())
        #expect(engine.tasksNeedingInput == 1)

        engine.setStatus(.needsInput, taskID: UUID(), tabID: UUID())
        #expect(engine.tasksNeedingInput == 2)
    }

    @Test func forgettingATabRemovesItFromItsTask() {
        let engine = StatusEngine()
        let (task, tab) = (UUID(), UUID())

        engine.setStatus(.needsInput, taskID: task, tabID: tab)
        engine.forget(tabID: tab, taskID: task)

        #expect(engine.status(forTask: task) == .unset)
        #expect(engine.tasksNeedingInput == 0)
    }

    @Test func registeringATabDoesNotOverwriteAKnownStatus() {
        let engine = StatusEngine()
        let (task, tab) = (UUID(), UUID())

        engine.setStatus(.working, taskID: task, tabID: tab)
        engine.register(tabID: tab, taskID: task, status: .idle)

        #expect(engine.status(forTab: tab) == .working)
    }
}
