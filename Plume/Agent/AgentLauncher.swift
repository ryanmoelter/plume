import GhosttyTerminal

/// Starts an agent in a tab's terminal.
///
/// An agent tab has no process until this runs — the plan's "launch on first
/// message" rule, so no idle `claude` processes sit around.
@MainActor
enum AgentLauncher {
    @discardableResult
    static func launch(
        message: String?,
        task: WorkTask,
        tab: TaskTab,
        resumeSessionID: String? = nil
    ) -> TerminalSession {
        let provider = ClaudeCodeProvider()
        let launch = provider.launchCommand(firstMessage: message, resumeSessionID: resumeSessionID)

        return SurfaceManager.shared.session(
            for: tab.id,
            options: TerminalSurfaceOptions(
                workingDirectory: task.workingDirectoryPath,
                envVars: launch.environment,
                command: launch.command
            )
        )
    }
}
