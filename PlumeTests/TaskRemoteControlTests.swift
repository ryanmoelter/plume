import Testing
import Foundation
@testable import Plume

/// The task context menu offers Remote Control only for a task with exactly
/// one agent tab, on the headless transport, whichever CLI it runs.
@MainActor
struct TaskRemoteControlTests {
    private func makeTask(tabs: [(kind: TabKind, provider: AgentProviderKind, transport: AgentTransport)]) -> WorkTask {
        let task = WorkTask(title: "Some Task", orderIndex: 0)
        task.tabs = tabs.enumerated().map { index, spec in
            let tab = TaskTab(kind: spec.kind, orderIndex: index, task: task)
            if spec.kind == .agent { tab.provider = spec.provider }
            tab.transport = spec.transport
            return tab
        }
        return task
    }

    @Test(arguments: [AgentProviderKind.claudeCode, .codex])
    func aSingleHeadlessAgentTabIsToggleable(provider: AgentProviderKind) {
        let task = makeTask(tabs: [(.agent, provider, .headless), (.terminal, .claudeCode, .terminal)])
        #expect(TaskRemoteControl.toggleableTab(in: task)?.id == task.orderedTabs.first?.id)
    }

    @Test(arguments: [AgentProviderKind.claudeCode, .codex])
    func aTerminalTransportAgentIsNotToggleable(provider: AgentProviderKind) {
        let task = makeTask(tabs: [(.agent, provider, .terminal)])
        #expect(TaskRemoteControl.toggleableTab(in: task) == nil)
    }

    @Test func twoAgentTabsAreNotToggleable() {
        let task = makeTask(tabs: [(.agent, .claudeCode, .headless), (.agent, .codex, .headless)])
        #expect(TaskRemoteControl.toggleableTab(in: task) == nil)
    }

    @Test func aTaskWithNoAgentTabIsNotToggleable() {
        let task = makeTask(tabs: [(.terminal, .claudeCode, .terminal)])
        #expect(TaskRemoteControl.toggleableTab(in: task) == nil)
    }
}
