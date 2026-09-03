import Foundation

/// Which context-menu actions an agent tab offers, given its transport.
///
/// Pure so the choice is testable without a live tab.
enum AgentTabMenu {
    static func transportSwitchLabel(for transport: AgentTransport) -> String {
        switch transport {
        case .headless: "Switch to Terminal Agent…"
        case .terminal: "Switch to Headless Agent…"
        }
    }

    static func targetTransport(switchingFrom transport: AgentTransport) -> AgentTransport {
        switch transport {
        case .headless: .terminal
        case .terminal: .headless
        }
    }
}
