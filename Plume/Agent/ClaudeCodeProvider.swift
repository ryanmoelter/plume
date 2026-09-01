import Foundation

/// Runs the `claude` CLI inside the tab's terminal, instrumented with hooks
/// that report status back to Plume.
struct ClaudeCodeProvider: AgentProvider {
    let id = ClaudeCodeProviderID

    /// Nil disables instrumentation, which degrades to a plain `claude`
    /// session rather than failing to launch.
    var settingsPath: String?

    init(settingsPath: String? = nil) {
        self.settingsPath = settingsPath
    }

    func launchCommand(firstMessage: String?, resumeSessionID: String?) -> AgentLaunch {
        launchCommand(firstMessage: firstMessage, resumeSessionID: resumeSessionID, taskID: nil, tabID: nil)
    }

    func launchCommand(
        firstMessage: String?,
        resumeSessionID: String?,
        taskID: UUID?,
        tabID: UUID?
    ) -> AgentLaunch {
        var arguments = ["claude"]

        if let settingsPath {
            arguments.append("--settings")
            arguments.append(shellQuoted(settingsPath))
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

        var environment: [String: String] = [:]
        if let taskID, let tabID {
            environment["PLUME_TASK_ID"] = taskID.uuidString
            environment["PLUME_TAB_ID"] = tabID.uuidString
            environment["PLUME_EVENTS_DIR"] = AppPaths.eventsDirectory.path
        }

        return AgentLaunch(command: arguments.joined(separator: " "), environment: environment)
    }
}
