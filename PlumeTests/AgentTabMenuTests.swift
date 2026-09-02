import Testing
@testable import Plume

struct AgentTabMenuTests {
    @Test func headlessTabOffersNoRenderModeAction() {
        #expect(AgentTabMenu.renderModeAction(for: .headless, renderMode: .chat) == nil)
        #expect(AgentTabMenu.renderModeAction(for: .headless, renderMode: .terminal) == nil)
    }

    @Test func terminalTabInChatOffersShowTerminal() {
        #expect(AgentTabMenu.renderModeAction(for: .terminal, renderMode: .chat) == .showTerminal)
    }

    @Test func terminalTabInTerminalOffersShowChat() {
        #expect(AgentTabMenu.renderModeAction(for: .terminal, renderMode: .terminal) == .showChat)
    }

    @Test func transportSwitchLabelNamesTheDestination() {
        #expect(AgentTabMenu.transportSwitchLabel(for: .headless) == "Switch to Terminal Agent…")
        #expect(AgentTabMenu.transportSwitchLabel(for: .terminal) == "Switch to Headless Agent…")
    }

    @Test func targetTransportIsTheOtherOne() {
        #expect(AgentTabMenu.targetTransport(switchingFrom: .headless) == .terminal)
        #expect(AgentTabMenu.targetTransport(switchingFrom: .terminal) == .headless)
    }
}
