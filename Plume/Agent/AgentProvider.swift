import Foundation

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
