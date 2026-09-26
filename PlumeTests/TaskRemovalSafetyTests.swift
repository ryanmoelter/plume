import Testing
import Foundation
@testable import Plume

/// Delete and archive confirm first only while an agent is mid-turn — working,
/// waiting on its subagents, or blocked on the user. An agent at rest removes
/// silently.
@MainActor
struct TaskRemovalSafetyTests {
    private func makeTask(tabs: [(kind: TabKind, transport: AgentTransport)]) -> WorkTask {
        let task = WorkTask(title: "Some Task", orderIndex: 0)
        task.tabs = tabs.enumerated().map { index, spec in
            let tab = TaskTab(kind: spec.kind, orderIndex: index, task: task)
            tab.transport = spec.transport
            return tab
        }
        return task
    }

    @Test(arguments: [
        TaskStatus.working, .waitingOnSubagents,
        .planApproval, .questionAsked, .permissionNeeded, .needsTerminalInput,
    ])
    func aMidTurnStatusNeedsConfirmation(status: TaskStatus) {
        #expect(TaskRemovalSafety.isMidTurn(status))
        #expect(TaskRemovalSafety.needsConfirmation([
            .init(status: .awaitingReply, hasExited: false),
            .init(status: status, hasExited: false),
        ]))
    }

    @Test(arguments: [TaskStatus.notStarted, .awaitingReply, .done, .interrupted, .error])
    func aRestingStatusRemovesSilently(status: TaskStatus) {
        #expect(!TaskRemovalSafety.isMidTurn(status))
        #expect(!TaskRemovalSafety.needsConfirmation([.init(status: status, hasExited: false)]))
    }

    @Test(arguments: [TaskStatus.working, .waitingOnSubagents, .permissionNeeded])
    func anExitedAgentRemovesSilentlyWhateverItsLastStatus(status: TaskStatus) {
        #expect(!TaskRemovalSafety.needsConfirmation([.init(status: status, hasExited: true)]))
    }

    @Test func aTaskWithNoAgentTabsNeedsNoConfirmation() {
        #expect(!TaskRemovalSafety.needsConfirmation([]))
    }

    /// A status left at `working` by a process that has gone reads as exited,
    /// since no session exists for the tab.
    @Test(arguments: [AgentTransport.headless, .terminal])
    func aWorkingStatusWithNoSessionRemovesSilently(transport: AgentTransport) throws {
        let task = makeTask(tabs: [(.agent, transport)])
        let tab = try #require(task.orderedTabs.first)
        StatusEngine.shared.setStatus(.working, taskID: task.id, tabID: tab.id, notifiable: false)
        defer { StatusEngine.shared.setStatus(.awaitingReply, taskID: task.id, tabID: tab.id, notifiable: false) }
        #expect(!TaskRemovalSafety.hasActiveAgent(task))
    }

    /// No status has ever been reported for these tabs, so they read as
    /// `notStarted`.
    @Test func aTaskWithNoReportedStatusHasNoActiveAgent() {
        let task = makeTask(tabs: [(.agent, .headless), (.agent, .terminal), (.terminal, .headless)])
        #expect(!TaskRemovalSafety.hasActiveAgent(task))
    }

    @Test func archiveAndDeleteWordTheMessageDifferently() {
        let task = WorkTask(title: "Some Task", orderIndex: 0)

        let archive = PendingLiveAgentRemoval(task: task, verb: .archive)
        #expect(archive.dialogTitle == "Archive “Some Task”?")
        #expect(archive.message.contains("Archiving"))

        let delete = PendingLiveAgentRemoval(task: task, verb: .delete)
        #expect(delete.dialogTitle == "Delete “Some Task”?")
        #expect(delete.message.contains("Deleting"))
        #expect(delete.message.contains("cannot be undone"))
    }
}
