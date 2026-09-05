import Testing
@testable import Plume

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
