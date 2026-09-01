import Foundation

/// Runs the `claude` CLI inside the tab's terminal.
///
/// Hook instrumentation (`--settings` plus the `PLUME_*` env vars the hooks
/// read) is added in WP3.1; this launches the CLI plainly.
struct ClaudeCodeProvider: AgentProvider {
    let id = ClaudeCodeProviderID

    func launchCommand(firstMessage: String?, resumeSessionID: String?) -> AgentLaunch {
        var arguments = ["claude"]

        if let resumeSessionID, !resumeSessionID.isEmpty {
            arguments.append("--resume")
            arguments.append(shellQuoted(resumeSessionID))
        }

        if let firstMessage {
            let trimmed = firstMessage.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                arguments.append(shellQuoted(trimmed))
            }
        }

        return AgentLaunch(command: arguments.joined(separator: " "), environment: [:])
    }
}
