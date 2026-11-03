import Foundation

/// Runs the `claude` CLI inside the tab's terminal, instrumented with hooks
/// that report status back to Plume.
struct ClaudeCodeProvider: AgentProvider {
    let kind = AgentProviderKind.claudeCode

    /// Nil disables instrumentation, which degrades to a plain `claude`
    /// session rather than failing to launch.
    var settingsPath: String?
    var additionalDirectories: [String]
    var systemPromptRulePath: String?

    init(settingsPath: String? = nil, additionalDirectories: [String] = [], systemPromptRulePath: String? = nil) {
        self.settingsPath = settingsPath
        self.additionalDirectories = additionalDirectories
        self.systemPromptRulePath = systemPromptRulePath
    }

    func launchCommand(
        firstMessage: String?,
        resumeSessionID: String?,
        taskID: UUID?,
        tabID: UUID?,
        permissionMode: String?
    ) -> AgentLaunch {
        var arguments = ["claude"]
        arguments += HeadlessCommand.addDirectoryArguments(additionalDirectories.map(shellQuoted))

        if let settingsPath {
            arguments.append("--settings")
            arguments.append(shellQuoted(settingsPath))
        }
        arguments += AgentPromptRule.arguments(path: systemPromptRulePath.map(shellQuoted))

        if let permissionMode {
            arguments.append("--permission-mode")
            arguments.append(permissionMode)
        }

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

        var environment = LoginShellCommand.plumeEnvironment
        if let taskID, let tabID {
            environment[CLISocket.taskIDEnvironmentKey] = taskID.uuidString
            environment[CLISocket.tabIDEnvironmentKey] = tabID.uuidString
            environment["PLUME_EVENTS_DIR"] = AppPaths.eventsDirectory.path
        }

        let command = LoginShellCommand.wrap(arguments.joined(separator: " "))
        return AgentLaunch(command: command, environment: environment)
    }
}
