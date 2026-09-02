import Foundation
import GhosttyTerminal
import os

/// Starts an agent in a tab, over whichever transport the tab selects.
///
/// An agent tab has no process until this runs — the plan's "launch on first
/// message" rule, so no idle `claude` processes sit around.
@MainActor
enum AgentLauncher {
    static func launch(
        message: String?,
        task: WorkTask,
        tab: TaskTab,
        resumeSessionID: String? = nil
    ) {
        switch tab.transport {
        case .headless:
            launchHeadless(message: message, task: task, tab: tab, resumeSessionID: resumeSessionID)
        case .terminal:
            launchTerminal(message: message, task: task, tab: tab, resumeSessionID: resumeSessionID)
        }
    }

    private static func launchHeadless(
        message: String?,
        task: WorkTask,
        tab: TaskTab,
        resumeSessionID: String?
    ) {
        // Instrumentation is best-effort: if the settings file cannot be
        // written, `claude` still launches, just without status reporting.
        let settingsPath = try? HookSettingsWriter.write().path
        if settingsPath == nil {
            Log.agent.error("Could not write hook settings; launching uninstrumented")
        }

        StatusEngine.shared.register(tabID: tab.id, taskID: task.id, status: .working)

        let session = HeadlessSessionManager.shared.session(for: tab.id, taskID: task.id)
        session.start(
            workingDirectory: task.workingDirectoryPath,
            permissionMode: task.permissionMode,
            resumeSessionID: resumeSessionID,
            settingsPath: settingsPath
        )
        if let message {
            session.submit(text: message)
        }
    }

    private static func launchTerminal(
        message: String?,
        task: WorkTask,
        tab: TaskTab,
        resumeSessionID: String?
    ) {
        // Instrumentation is best-effort: if the settings file cannot be
        // written, `claude` still launches, just without status reporting.
        let settingsPath = try? HookSettingsWriter.write().path
        if settingsPath == nil {
            Log.agent.error("Could not write hook settings; launching uninstrumented")
        }

        let provider = AgentProviderRegistry.provider(
            for: AppSettings.shared.providerID,
            settingsPath: settingsPath
        )
        let launch = provider.launchCommand(
            firstMessage: message,
            resumeSessionID: resumeSessionID,
            taskID: settingsPath == nil ? nil : task.id,
            tabID: settingsPath == nil ? nil : tab.id,
            permissionMode: task.permissionMode
        )

        if settingsPath != nil {
            AgentEventMonitor.shared.watch(taskID: task.id, tabID: tab.id)
            StatuslineStore.shared.watch(tabID: tab.id, taskID: task.id)
        }
        StatusEngine.shared.register(tabID: tab.id, taskID: task.id, status: .working)

        SurfaceManager.shared.session(
            for: tab.id,
            options: TerminalSurfaceOptions(
                workingDirectory: task.workingDirectoryPath,
                envVars: launch.environment,
                command: launch.command
            )
        )
    }
}
