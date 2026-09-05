import Foundation

/// Which context-menu actions an agent tab offers, given its transport.
///
/// Pure so the choice is testable without a live tab.
enum AgentTabMenu {
    static func transportSwitchLabel(
        for transport: AgentTransport,
        provider: AgentProviderKind? = nil
    ) -> String {
        let name = provider.map { " \($0.displayName)" } ?? " Agent"
        return switch transport {
        case .headless: "Switch to Terminal\(name)…"
        case .terminal: "Switch to Headless\(name)…"
        }
    }

    static func targetTransport(switchingFrom transport: AgentTransport) -> AgentTransport {
        switch transport {
        case .headless: .terminal
        case .terminal: .headless
        }
    }
}
