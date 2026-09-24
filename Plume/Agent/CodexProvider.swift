import Foundation

/// Runs the `codex` TUI inside the tab's terminal.
///
/// The escape hatch for what the headless transport cannot do — `codex login`,
/// and anything the app-server protocol does not expose. Plume launches the
/// TUI against a private owned app-server; a read-only observer tracks its
/// status while the TUI retains all input and approval handling.
struct CodexProvider: AgentProvider {
    let kind = AgentProviderKind.codex
    var remoteSocket: String? = nil

    func launchCommand(
        firstMessage: String?,
        resumeSessionID: String?,
        taskID: UUID?,
        tabID: UUID?,
        permissionMode: String?
    ) -> AgentLaunch {
        var arguments = ["codex"]
        if let remoteSocket {
            arguments += ["--remote", shellQuoted("unix://" + remoteSocket)]
        }

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

        var command = arguments.joined(separator: " ")
        if let remoteSocket {
            // The PTY can mount before the server finishes starting. Bound
            // the wait and report a real failure rather than opening a new,
            // unobserved Codex session as a fallback.
            let path = shellQuoted(remoteSocket)
            command = "n=0; while [ ! -S " + path + " ] && [ \"$n\" -lt 200 ]; do sleep 0.05; n=$((n+1)); done; [ -S " + path + " ] || exit 1; " + command
        }
        return AgentLaunch(
            command: LoginShellCommand.wrap(command),
            environment: LoginShellCommand.plumeEnvironment
        )
    }
}
