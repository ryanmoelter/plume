import Foundation
import GhosttyTerminal
import os

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
        // Instrumentation is best-effort: if the settings file cannot be
        // written, `claude` still launches, just without status reporting.
        let settingsPath = try? HookSettingsWriter.write().path
        if settingsPath == nil {
            Log.agent.error("Could not write hook settings; launching uninstrumented")
        }

        let provider = ClaudeCodeProvider(settingsPath: settingsPath)
        let launch = provider.launchCommand(
            firstMessage: message,
            resumeSessionID: resumeSessionID,
            taskID: settingsPath == nil ? nil : task.id,
            tabID: settingsPath == nil ? nil : tab.id
        )

        if settingsPath != nil {
            AgentEventMonitor.shared.watch(taskID: task.id, tabID: tab.id)
        }
        StatusEngine.shared.register(tabID: tab.id, taskID: task.id, status: .working)

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
