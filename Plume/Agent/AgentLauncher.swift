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
        switch (tab.provider, tab.transport) {
        case (.claudeCode, .headless):
            launchClaudeHeadless(message: message, task: task, tab: tab, resumeSessionID: resumeSessionID)
        case (.claudeCode, .terminal):
            launchClaudeTerminal(message: message, task: task, tab: tab, resumeSessionID: resumeSessionID)
        case (.codex, .headless):
            launchCodexHeadless(message: message, task: task, tab: tab, resumeSessionID: resumeSessionID)
        case (.codex, .terminal):
            launchCodexTerminal(message: message, task: task, tab: tab, resumeSessionID: resumeSessionID)
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
            AgentSessionManager.shared.closeSession(for: tab.id)
        case .terminal:
            SurfaceManager.shared.closeSession(for: tab.id)
        }
        tab.transport = newTransport
        launch(message: nil, task: task, tab: tab, resumeSessionID: tab.agentSessionID)
    }

    private static func launchClaudeHeadless(
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

        // Spawning without the CLI present would die on the login shell's own
        // "command not found", which reaches the user only as a dead session.
        // Reporting it before the process exists says the same thing with the
        // remedy attached.
        guard ClaudeCLILocator.isAvailable() else {
            let session = HeadlessSessionManager.shared.session(
                for: tab.id,
                taskID: task.id,
                initialEffort: tab.effort ?? AppSettings.shared.defaultEffort
            )
            session.failToLaunch(reason: "claude: command not found")
            return
        }

        // Instrumentation is best-effort: if the settings file cannot be
        // written, `claude` still launches, just without status reporting.
        let settingsPath = try? HookSettingsWriter.write().path
        if settingsPath == nil {
            Log.agent.error("Could not write hook settings; launching uninstrumented")
        }

        StatusEngine.shared.register(tabID: tab.id, taskID: task.id, status: .working)

        let existing = AgentSessionManager.shared.session(
            for: tab.id,
            taskID: task.id,
            provider: .claudeCode,
            initialEffort: tab.effort ?? AppSettings.shared.defaultEffort
        )
        guard let session = existing as? HeadlessSession else {
            Log.agent.error("Tab \(tab.id, privacy: .public) already holds another CLI's session")
            return
        }
        session.start(
            workingDirectory: task.workingDirectoryPath,
            permissionMode: resolvedPermissionMode(
                tab: tab.permissionMode,
                task: task.permissionMode,
                appDefault: AppSettings.shared.resolvedDefaultPermissionMode
            ),
            resumeSessionID: resumeSessionID,
            settingsPath: settingsPath,
            model: tab.model,
            isModelExplicitlyChosen: tab.isModelUserChosen,
            environment: LoginShellCommand.plumeEnvironment
        )
        if let message {
            session.submit(text: message)
        }
    }

    /// Codex reports over its own protocol, so this launch carries none of
    /// Claude Code's hook instrumentation or folder-trust check.
    private static func launchCodexTerminal(
        message: String?,
        task: WorkTask,
        tab: TaskTab,
        resumeSessionID: String?
    ) {
        let provider = AgentProviderRegistry.provider(for: .codex, settingsPath: nil)
        let launch = provider.launchCommand(
            firstMessage: message,
            resumeSessionID: resumeSessionID,
            taskID: nil,
            tabID: nil,
            permissionMode: nil
        )
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

    private static func launchCodexHeadless(
        message: String?,
        task: WorkTask,
        tab: TaskTab,
        resumeSessionID: String?
    ) {
        StatusEngine.shared.register(tabID: tab.id, taskID: task.id, status: .working)

        let existing = AgentSessionManager.shared.session(
            for: tab.id,
            taskID: task.id,
            provider: .codex,
            initialEffort: tab.effort ?? AppSettings.shared.defaultEffort
        )
        guard let session = existing as? CodexSession else {
            Log.agent.error("Tab \(tab.id, privacy: .public) already holds another CLI's session")
            return
        }
        session.start(
            workingDirectory: task.workingDirectoryPath,
            resumeThreadID: resumeSessionID,
            model: tab.model,
            permissionProfile: tab.permissionPreset?.id ?? AppSettings.shared.defaultCodexPermissionProfile.id,
            environment: LoginShellCommand.plumeEnvironment
        )
        if let message {
            session.submit(text: message)
        }
    }

    private static func launchClaudeTerminal(
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

        let provider = AgentProviderRegistry.provider(for: .claudeCode, settingsPath: settingsPath)
        let launch = provider.launchCommand(
            firstMessage: message,
            resumeSessionID: resumeSessionID,
            taskID: settingsPath == nil ? nil : task.id,
            tabID: settingsPath == nil ? nil : tab.id,
            permissionMode: (task.permissionMode ?? AppSettings.shared.resolvedDefaultPermissionMode)?.token
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
