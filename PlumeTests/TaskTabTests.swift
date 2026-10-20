import SwiftData
import Testing
@testable import Plume

@MainActor
struct TaskTabTests {
    @Test func permissionModeRoundTripsThroughItsRawString() {
        let tab = TaskTab(kind: .agent, orderIndex: 0)
        #expect(tab.permissionMode == nil)

        tab.permissionMode = .acceptEdits
        #expect(tab.permissionModeRaw == PermissionMode.acceptEdits.rawValue)
        #expect(tab.permissionMode == .acceptEdits)

        tab.permissionMode = nil
        #expect(tab.permissionModeRaw == nil)
    }

    @Test func effortRoundTripsThroughItsRawString() {
        let tab = TaskTab(kind: .agent, orderIndex: 0)
        #expect(tab.effort == nil)

        tab.effort = .xhigh
        #expect(tab.effortRaw == AgentEffort.xhigh.rawValue)
        #expect(tab.effort == .xhigh)

        tab.effort = nil
        #expect(tab.effortRaw == nil)
    }

    @Test func unrecognizedRawPermissionModeReadsAsNil() {
        let tab = TaskTab(kind: .agent, orderIndex: 0)
        tab.permissionModeRaw = "not-a-real-mode"
        #expect(tab.permissionMode == nil)
    }

    @Test func unrecognizedRawEffortReadsAsNil() {
        let tab = TaskTab(kind: .agent, orderIndex: 0)
        tab.effortRaw = "not-a-real-effort"
        #expect(tab.effort == nil)
    }
}

@MainActor
struct WorkTaskHasNeverStartedTests {
    private let context: ModelContext

    init() throws {
        let container = try ModelContainer(
            for: Schema([TaskGroup.self, WorkTask.self, TaskTab.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        context = ModelContext(container)
    }

    private func makeTask() -> WorkTask {
        let task = WorkTask(title: "", orderIndex: 0)
        context.insert(task)
        return task
    }

    @Test func trueWithNoTabs() {
        let task = makeTask()
        #expect(task.hasNeverStarted)
    }

    @Test func trueWhenAgentTabHasNoSessionID() {
        let task = makeTask()
        task.tabs = [TaskTab(kind: .agent, orderIndex: 0, task: task)]
        #expect(task.hasNeverStarted)
    }

    @Test func falseOnceAnAgentTabHasASessionID() {
        let task = makeTask()
        let tab = TaskTab(kind: .agent, orderIndex: 0, task: task)
        tab.agentSessionID = "session-1"
        task.tabs = [tab]
        #expect(!task.hasNeverStarted)
    }

    @Test func terminalTabSessionIDDoesNotCount() {
        let task = makeTask()
        let tab = TaskTab(kind: .terminal, orderIndex: 0, task: task)
        tab.agentSessionID = "session-1"
        task.tabs = [tab]
        #expect(task.hasNeverStarted)
    }

    @Test func trueAfterRelaunchEvenThoughStatusCollapsesToNotStarted() {
        // The predicate must outlive a relaunch's status collapse: a task
        // that ran and lost its process is not "never started."
        let task = makeTask()
        let tab = TaskTab(kind: .agent, orderIndex: 0, task: task)
        tab.agentSessionID = "session-1"
        task.tabs = [tab]
        task.lastStatus = .working
        #expect(task.lastStatus.afterRelaunch == .notStarted)
        #expect(!task.hasNeverStarted)
    }
}

@MainActor
struct AgentLauncherPermissionModePrecedenceTests {
    @Test func tabModeWinsOverTaskAndAppDefault() {
        #expect(AgentLauncher.resolvedPermissionMode(
            tab: .bypassPermissions,
            task: .plan,
            appDefault: .auto
        ) == .bypassPermissions)
    }

    @Test func taskModeWinsWhenTabHasNone() {
        #expect(AgentLauncher.resolvedPermissionMode(
            tab: nil,
            task: .plan,
            appDefault: .auto
        ) == .plan)
    }

    @Test func appDefaultAppliesOnlyWhenTabAndTaskHaveNone() {
        #expect(AgentLauncher.resolvedPermissionMode(
            tab: nil,
            task: nil,
            appDefault: .auto
        ) == .auto)
    }

    @Test func allNilResolvesToNil() {
        #expect(AgentLauncher.resolvedPermissionMode(tab: nil, task: nil, appDefault: nil) == nil)
    }
}
