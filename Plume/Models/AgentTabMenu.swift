import Foundation

/// Which context-menu actions an agent tab offers, given its transport and
/// current render mode.
///
/// Pure so the choice is testable without a live tab. A headless tab has no
/// PTY, so "show the terminal view" is meaningless there — the render-mode
/// toggle only applies to a terminal-transport tab, which can genuinely show
/// either view. The transport switch is the other axis: it changes which
/// process drives the tab, and is offered regardless of render mode.
enum AgentTabMenu {
    enum RenderModeAction {
        case showTerminal
        case showChat
    }

    /// Nil when a headless tab's only view is chat, so there is nothing to
    /// toggle to.
    static func renderModeAction(for transport: AgentTransport, renderMode: TabRenderMode) -> RenderModeAction? {
        guard transport == .terminal else { return nil }
        return renderMode == .chat ? .showTerminal : .showChat
    }

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
