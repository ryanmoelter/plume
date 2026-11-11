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

    static let refreshLabel = "Refresh Conversation"

    /// Headless Codex tabs share one app-server, which a refresh would leave
    /// running, so it would reload nothing.
    static func offersRefresh(provider: AgentProviderKind, transport: AgentTransport, hasConversation: Bool) -> Bool {
        hasConversation && !(provider == .codex && transport == .headless)
    }

    /// Whether restarting the process would cut short a turn, a pending
    /// answer, a subagent or a background task, so the user is asked first.
    static func refreshInterruptsWork(status: TaskStatus, backgroundTaskCount: Int, sessionIsBusy: Bool) -> Bool {
        if sessionIsBusy || backgroundTaskCount > 0 { return true }
        return switch status {
        case .working, .waitingOnSubagents, .planApproval, .questionAsked, .permissionNeeded, .needsTerminalInput: true
        case .notStarted, .awaitingReply, .done, .interrupted, .interruptedByRestart, .error: false
        }
    }
}
