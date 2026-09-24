import Foundation
import os

struct AgentLaunch {
    /// Command line for the surface's child process.
    let command: String
    let environment: [String: String]
}

/// A coding agent Plume can run in a terminal tab.
///
/// This covers the terminal transport only. The headless transport talks its
/// provider's own JSON protocol and is dispatched by `AgentLauncher` instead.
protocol AgentProvider {
    var kind: AgentProviderKind { get }

    /// `firstMessage` starts a new conversation; `resumeSessionID` continues a
    /// prior one. Passing both resumes and then sends the message.
    ///
    /// `permissionMode` is the provider's own token, not a shared vocabulary —
    /// Claude Code's `--permission-mode` names and Codex's permission profiles
    /// have no values in common.
    func launchCommand(
        firstMessage: String?,
        resumeSessionID: String?,
        taskID: UUID?,
        tabID: UUID?,
        permissionMode: String?
    ) -> AgentLaunch
}

/// Quotes a string for safe use as a single shell word.
func shellQuoted(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
}

/// Resolves a provider to its implementation.
enum AgentProviderRegistry {
    static func provider(for kind: AgentProviderKind, settingsPath: String?) -> any AgentProvider {
        switch kind {
        case .claudeCode:
            return ClaudeCodeProvider(settingsPath: settingsPath)
        case .codex:
            return CodexProvider()
        }
    }
}
