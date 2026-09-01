import Foundation
import os

struct AgentLaunch {
    /// Command line for the surface's child process.
    let command: String
    let environment: [String: String]
}

/// A coding agent Plume can run in a terminal tab. Claude Code is the only
/// provider in v1; the protocol is the seam for Codex and local models later.
protocol AgentProvider {
    var id: String { get }

    /// `firstMessage` starts a new conversation; `resumeSessionID` continues a
    /// prior one. Passing both resumes and then sends the message.
    func launchCommand(firstMessage: String?, resumeSessionID: String?) -> AgentLaunch
}

/// Quotes a string for safe use as a single shell word.
func shellQuoted(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
}

/// Resolves a provider ID (from Settings) to its implementation. Only
/// `claude-code` exists in v1; anything else falls back to it rather than
/// failing to launch.
enum AgentProviderRegistry {
    static func provider(for id: String, settingsPath: String?) -> ClaudeCodeProvider {
        switch id {
        case ClaudeCodeProviderID:
            return ClaudeCodeProvider(settingsPath: settingsPath)
        default:
            Log.agent.error("Unknown provider id \"\(id, privacy: .public)\"; falling back to Claude Code")
            return ClaudeCodeProvider(settingsPath: settingsPath)
        }
    }
}
