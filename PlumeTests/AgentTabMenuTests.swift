import Testing
@testable import Plume

@MainActor
struct AgentTabMenuTests {
    @Test func transportSwitchLabelNamesTheDestination() {
        #expect(AgentTabMenu.transportSwitchLabel(for: .headless) == "Switch to Terminal Agent…")
        #expect(AgentTabMenu.transportSwitchLabel(for: .terminal) == "Switch to Headless Agent…")
        #expect(AgentTabMenu.transportSwitchLabel(for: .headless, provider: .codex) == "Switch to Terminal Codex…")
    }

    @Test func targetTransportIsTheOtherOne() {
        #expect(AgentTabMenu.targetTransport(switchingFrom: .headless) == .terminal)
        #expect(AgentTabMenu.targetTransport(switchingFrom: .terminal) == .headless)
    }
}

@MainActor
struct AgentTabMenuRefreshTests {
    @Test func refreshIsOfferedOnlyWithAConversationAndAProcessOfItsOwn() {
        #expect(AgentTabMenu.offersRefresh(provider: .claudeCode, transport: .headless, hasConversation: true))
        #expect(AgentTabMenu.offersRefresh(provider: .claudeCode, transport: .terminal, hasConversation: true))
        #expect(AgentTabMenu.offersRefresh(provider: .codex, transport: .terminal, hasConversation: true))
        #expect(!AgentTabMenu.offersRefresh(provider: .codex, transport: .headless, hasConversation: true))
        #expect(!AgentTabMenu.offersRefresh(provider: .claudeCode, transport: .headless, hasConversation: false))
    }

    @Test(arguments: TaskStatus.allCases)
    func refreshAsksFirstOnlyWhileWorkIsUnderWay(status: TaskStatus) {
        let underWay: Set<TaskStatus> = [
            .working, .waitingOnSubagents, .planApproval, .questionAsked, .permissionNeeded, .needsTerminalInput
        ]
        #expect(AgentTabMenu.refreshInterruptsWork(status: status, backgroundTaskCount: 0, sessionIsBusy: false)
            == underWay.contains(status))
        #expect(AgentTabMenu.refreshInterruptsWork(status: status, backgroundTaskCount: 1, sessionIsBusy: false))
        #expect(AgentTabMenu.refreshInterruptsWork(status: status, backgroundTaskCount: 0, sessionIsBusy: true))
    }
}
