import Testing
import Foundation
@testable import Plume

/// The decision of whether delete or archive needs to confirm a live agent
/// first — kept separate from the session lookup so it's testable without a
/// running process.
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

    @Test func aLiveAgentTabIsLive() {
        #expect(TaskRemovalSafety.isLive(kind: .agent, hasExited: false))
    }

    @Test func anExitedAgentTabIsNotLive() {
        #expect(!TaskRemovalSafety.isLive(kind: .agent, hasExited: true))
    }

    @Test func aTerminalTabIsNeverLive() {
        #expect(!TaskRemovalSafety.isLive(kind: .terminal, hasExited: false))
    }

    /// No session has ever run for these tabs, so the lookup reads them as
    /// exited and the task needs no confirmation.
    @Test func aTaskWithNoRunningSessionHasNoLiveAgent() {
        let task = makeTask(tabs: [(.agent, .headless), (.agent, .terminal), (.terminal, .headless)])
        #expect(!TaskRemovalSafety.hasLiveAgent(task))
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
