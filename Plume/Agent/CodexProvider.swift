import Foundation

/// Runs the `codex` TUI inside the tab's terminal.
///
/// The escape hatch for what the headless transport cannot do — `codex login`,
/// and anything the app-server protocol does not expose. Codex reports status
/// over its own protocol, so a terminal Codex tab carries no instrumentation
/// and stays dark in the sidebar.
struct CodexProvider: AgentProvider {
    let kind = AgentProviderKind.codex

    func launchCommand(
        firstMessage: String?,
        resumeSessionID: String?,
        taskID: UUID?,
        tabID: UUID?,
        permissionMode: String?
    ) -> AgentLaunch {
        var arguments = ["codex"]

        if let resumeSessionID, !resumeSessionID.isEmpty {
            arguments.append("resume")
            arguments.append(shellQuoted(resumeSessionID))
        }

        // A permission profile reaches the CLI as a config override rather
        // than a flag of its own.
        if let permissionMode, !permissionMode.isEmpty {
            arguments.append("-c")
            arguments.append(shellQuoted("permissions=\"\(permissionMode)\""))
        }

        if let firstMessage {
            let trimmed = firstMessage.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                arguments.append(shellQuoted(trimmed))
            }
        }

        return AgentLaunch(
            command: LoginShellCommand.wrap(arguments.joined(separator: " ")),
            environment: LoginShellCommand.plumeEnvironment
        )
    }
}
