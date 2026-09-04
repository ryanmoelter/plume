import Foundation
import GhosttyTerminal
import os

/// Starts an agent in a tab, over whichever transport the tab selects.
///
/// An agent tab has no process until this runs — the plan's "launch on first
/// message" rule, so no idle `claude` processes sit around.
@MainActor
enum AgentLauncher {
    /// Tab beats task beats app default: a tab reopens in the mode the user
    /// last saw it in, and the app default only fills in for a tab that has
    /// never had one, so changing the default never retroactively moves an
    /// existing conversation.
    static func resolvedPermissionMode(
        tab: PermissionMode?,
        task: PermissionMode?,
        appDefault: PermissionMode?
    ) -> PermissionMode? {
        tab ?? task ?? appDefault
    }

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

    /// Ends the tab's current process and relaunches it on the other
    /// transport, resuming the same Claude Code session when one exists.
    ///
    /// The tab's `agentSessionID` is what makes this a continuation rather
    /// than a fresh conversation — both transports write it, and both accept
    /// it as `--resume`, so switching transport doesn't have to switch
    /// conversation.
    static func switchTransport(task: WorkTask, tab: TaskTab) {
        let newTransport = AgentTabMenu.targetTransport(switchingFrom: tab.transport)
        switch tab.transport {
        case .headless:
            HeadlessSessionManager.shared.closeSession(for: tab.id)
        case .terminal:
            SurfaceManager.shared.closeSession(for: tab.id)
        }
        tab.transport = newTransport
        launch(message: nil, task: task, tab: tab, resumeSessionID: tab.agentSessionID)
    }

    private static func launchHeadless(
        message: String?,
        task: WorkTask,
        tab: TaskTab,
        resumeSessionID: String?
    ) {
        // The headless transport has no way to surface Claude Code's
        // folder-trust prompt, so an untrusted directory would otherwise
        // hang the turn with nothing to look at. Refuse to spawn instead,
        // and point at the terminal transport, where the prompt can
        // actually be answered. Never write the trust flag here — that
        // would grant the very trust the prompt exists to ask for.
        guard let workingDirectory = task.workingDirectoryPath else { return }
        guard ClaudeTrustStore.isTrusted(workingDirectory) else {
            UntrustedDirectoryStore.shared.markUntrusted(tabID: tab.id, path: workingDirectory)
            return
        }
        UntrustedDirectoryStore.shared.clear(tabID: tab.id)

        // Instrumentation is best-effort: if the settings file cannot be
        // written, `claude` still launches, just without status reporting.
        let settingsPath = try? HookSettingsWriter.write().path
        if settingsPath == nil {
            Log.agent.error("Could not write hook settings; launching uninstrumented")
        }

        StatusEngine.shared.register(tabID: tab.id, taskID: task.id, status: .working)

        let session = HeadlessSessionManager.shared.session(
            for: tab.id,
            taskID: task.id,
            initialEffort: tab.effort
        )
        session.start(
            workingDirectory: task.workingDirectoryPath,
            permissionMode: resolvedPermissionMode(
                tab: tab.permissionMode,
                task: task.permissionMode,
                appDefault: AppSettings.shared.resolvedDefaultPermissionMode
            ),
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
            permissionMode: task.permissionMode ?? AppSettings.shared.resolvedDefaultPermissionMode
        )

        if settingsPath != nil {
            AgentEventMonitor.shared.watch(taskID: task.id, tabID: tab.id)
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
