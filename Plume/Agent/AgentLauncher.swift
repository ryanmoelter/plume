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
        launch(blocks: message.map { [.text($0)] } ?? [], task: task, tab: tab, resumeSessionID: resumeSessionID)
    }

    /// `fork` branches the resumed conversation into a new session instead of
    /// continuing it, and `sessionID` names a new conversation up front. Both
    /// are honoured on Claude Code's headless transport only — no other path
    /// has a way to pass them through. So is `effort`, which only a child
    /// session launches with; every other launch sets effort with `/effort`.
    static func launch(
        blocks: [UserContentBlock],
        task: WorkTask,
        tab: TaskTab,
        resumeSessionID: String? = nil,
        fork: HeadlessCommand.Fork? = nil,
        sessionID: String? = nil,
        effort: AgentEffort? = nil
    ) {
        let normalized = blocks.normalized
        let text = normalized.plainText
        switch (tab.provider, tab.transport) {
        case (.claudeCode, .headless):
            launchClaudeHeadless(
                blocks: normalized, task: task, tab: tab, resumeSessionID: resumeSessionID, fork: fork,
                sessionID: sessionID, effort: effort
            )
        case (.claudeCode, .terminal):
            launchClaudeTerminal(message: text.isEmpty ? nil : text, task: task, tab: tab, resumeSessionID: resumeSessionID)
        case (.codex, .headless):
            launchCodexHeadless(blocks: normalized, task: task, tab: tab, resumeSessionID: resumeSessionID)
        case (.codex, .terminal):
            launchCodexTerminal(message: text.isEmpty ? nil : text, task: task, tab: tab, resumeSessionID: resumeSessionID)
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
        if newTransport == .terminal {
            // A `.reply` only ever comes from the headless control plane,
            // which switching off means for good — left in place, it would
            // outrank and block every `ai-title` the TUI writes from here on.
            TitleStore.shared.demoteSource(forTab: tab.id, to: .transcript)
            if tab.titleSource == .reply {
                tab.titleSource = .transcript
            }
        }
        launch(message: nil, task: task, tab: tab, resumeSessionID: tab.agentSessionID)
    }

    /// Ends the tab's process and starts a new one on the same transport,
    /// resuming the same conversation, so the CLI rereads its settings,
    /// skills and MCP servers.
    static func refresh(task: WorkTask, tab: TaskTab) {
        switch (tab.provider, tab.transport) {
        case (.claudeCode, .headless):
            if !restartHeadless(task: task, tab: tab) { relaunchHeadless(task: task, tab: tab) }
        case (.codex, .headless):
            AgentSessionManager.shared.closeSession(for: tab.id)
            launch(message: nil, task: task, tab: tab, resumeSessionID: tab.agentSessionID)
        case (_, .terminal):
            SurfaceManager.shared.closeSession(for: tab.id)
            launch(message: nil, task: task, tab: tab, resumeSessionID: tab.agentSessionID)
        }
    }

    /// Replaces the tab's headless session with a new process resuming the
    /// same conversation. Unsent messages, side chats, the title policy and
    /// Remote Control live only in the old session, so they move across.
    ///
    /// For a session that has exited, or none at all. A running one goes
    /// through `restartHeadless`, which waits for its process to exit.
    @discardableResult
    static func relaunchHeadless(task: WorkTask, tab: TaskTab) -> (any AgentSession)? {
        let previous = AgentSessionManager.shared.existingSession(for: tab.id)
        let queued = queue(of: previous)
        if let previous = previous as? HeadlessSession { persistLiveSettings(of: previous, to: tab) }
        if previous != nil { AgentSessionManager.shared.closeSession(for: tab.id) }
        return resume(task: task, tab: tab, inheriting: previous, queued: queued)
    }

    /// Restarts a running headless session so it relaunches with the tab's
    /// current settings. The resumed process starts only once the old one
    /// has exited.
    ///
    /// False when nothing would launch, leaving the old session running:
    /// no running session, no conversation to resume, or a launch the
    /// pre-flight checks would refuse.
    @discardableResult
    static func restartHeadless(task: WorkTask, tab: TaskTab) -> Bool {
        guard let previous = AgentSessionManager.shared.existingSession(for: tab.id) as? HeadlessSession,
              !previous.hasExited
        else { return false }
        persistLiveSettings(of: previous, to: tab)
        guard let sessionID = tab.agentSessionID, !sessionID.isEmpty,
              let workingDirectory = claudeLaunchDirectory(for: tab, resumeSessionID: sessionID),
              ClaudeTrustStore.isTrusted(workingDirectory),
              ClaudeCLILocator.isAvailable()
        else { return false }
        let exiting = previous.stopForRestart()
        Task { [weak tab] in
            await exiting?.waitUntilExited()
            // Closing the tab or its session meanwhile cancels the resume.
            guard let tab,
                  AgentSessionManager.shared.existingSession(for: tab.id) as? HeadlessSession === previous
            else { return }
            _ = AgentSessionManager.shared.detachSession(for: tab.id)
            resume(task: tab.task ?? task, tab: tab, inheriting: previous, queued: previous.queue)
        }
        return true
    }

    private static func queue(of session: (any AgentSession)?) -> [QueuedMessage] {
        if let headless = session as? HeadlessSession { return headless.queue }
        return (session?.queuedMessages ?? []).map { QueuedMessage(parts: [.user($0)]) }
    }

    /// A launch that fails still leaves a failed session holding the
    /// messages, so the reconnect it offers delivers them.
    @discardableResult
    private static func resume(
        task: WorkTask,
        tab: TaskTab,
        inheriting previous: (any AgentSession)?,
        queued: [QueuedMessage]
    ) -> (any AgentSession)? {
        launch(message: nil, task: task, tab: tab, resumeSessionID: tab.agentSessionID)
        let resumed = AgentSessionManager.shared.existingSession(for: tab.id)
        if let previous = previous as? HeadlessSession, let resumed = resumed as? HeadlessSession {
            resumed.inherit(from: previous)
        }
        if let resumed = resumed as? HeadlessSession {
            if resumed.hasExited {
                resumed.requeue(queued)
            } else {
                for message in queued { resumed.submit(message) }
            }
        } else if let resumed {
            for message in queued { resumed.submit(blocks: message.display) }
        } else if !queued.isEmpty {
            let parts = queued.flatMap(\.parts)
            if let written = parts.userBlocks {
                let draft = [DraftStore.shared.draft(forTab: tab.id), written.plainText]
                DraftStore.shared.setDraft(draft.filter { !$0.isEmpty }.joined(separator: "\n\n"), forTab: tab.id)
            }
            (previous as? HeadlessSession)?.onHostMessagesReturned?(parts.hosts)
        }
        return resumed
    }

    /// What the session changed on its own, such as leaving plan mode, is
    /// otherwise saved only by a mounted chat view, and the resume reads the tab.
    ///
    /// A mode or model the tab only inherited stays unset, so the tab keeps
    /// following the default rather than pinning today's value.
    private static func persistLiveSettings(of session: HeadlessSession, to tab: TaskTab) {
        if let sessionID = session.sessionID, !sessionID.isEmpty, tab.agentSessionID == nil {
            recordSessionID(sessionID, on: tab)
        }
        if let mode = session.permissionMode, tab.permissionMode != mode {
            let inherited = resolvedPermissionMode(
                tab: tab.permissionMode,
                task: tab.task?.permissionMode,
                appDefault: AppSettings.shared.resolvedDefaultPermissionMode
            )
            if tab.permissionMode != nil || mode != inherited { tab.permissionMode = mode }
        }
        if tab.isModelUserChosen, let model = session.model, tab.model != model { tab.model = model }
        if let effort = session.effort, tab.effort != effort { tab.effort = effort }
    }

    /// Records a headless session's id with the transcript it writes, which
    /// the chat watches.
    static func recordSessionID(_ sessionID: String, on tab: TaskTab) {
        tab.agentSessionID = sessionID
        // Only Claude Code keeps a transcript on disk; Codex serves its
        // history over the protocol, so a Codex tab has no path to derive.
        guard tab.provider == .claudeCode, let workingDirectory = TabDirectoryStore.shared.directory(for: tab) else { return }
        tab.sessionJSONLPath = SessionJSONLReader.resolvedTranscriptPath(
            workingDirectory: workingDirectory,
            sessionID: sessionID
        )
    }

    private static func launchClaudeHeadless(
        blocks: [UserContentBlock],
        task: WorkTask,
        tab: TaskTab,
        resumeSessionID: String?,
        fork: HeadlessCommand.Fork? = nil,
        sessionID: String? = nil,
        effort: AgentEffort? = nil
    ) {
        // `claude -p` skips the folder-trust prompt outright rather than
        // blocking on it, so a directory the user never accepted would run
        // unasked. Refuse instead, and point at the terminal transport, where
        // the prompt can actually be answered. Never write the trust flag
        // here — that would grant the very trust the prompt exists to ask for.
        guard let workingDirectory = claudeLaunchDirectory(for: tab, resumeSessionID: resumeSessionID) else { return }

        guard ClaudeTrustStore.isTrusted(workingDirectory) else {
            UntrustedDirectoryStore.shared.markUntrusted(tabID: tab.id, path: workingDirectory)
            // Also reported through the session, so a refusal that follows a
            // sent message lands in the conversation beside it. The full-pane
            // state only shows while the conversation is empty, which a
            // just-sent message it never spawned for is not.
            let session = AgentSessionManager.shared.session(
                for: tab.id, taskID: task.id, provider: .claudeCode,
                initialEffort: tab.effort ?? AppSettings.shared.defaultEffort
            ) as? HeadlessSession
            session?.failToLaunch(failure: .untrustedDirectory(path: workingDirectory))
            return
        }
        UntrustedDirectoryStore.shared.clear(tabID: tab.id)

        // Spawning without the CLI present would die on the login shell's own
        // "command not found", which reaches the user only as a dead session.
        // Reporting it before the process exists says the same thing with the
        // remedy attached.
        guard ClaudeCLILocator.isAvailable() else {
            let existing = AgentSessionManager.shared.session(
                for: tab.id,
                taskID: task.id,
                initialEffort: tab.effort ?? AppSettings.shared.defaultEffort
            )
            guard let session = existing as? HeadlessSession else { return }
            session.failToLaunch(reason: "claude: command not found")
            return
        }

        // Instrumentation is best-effort: if the settings file cannot be
        // written, `claude` still launches, just without status reporting.
        let settingsPath = try? HookSettingsWriter.write().path
        if settingsPath == nil {
            Log.agent.error("Could not write hook settings; launching uninstrumented")
        }

        // A launch with no prompt runs no turn, so nothing would end it. A
        // prompt reports `.working` itself once submitted.
        StatusEngine.shared.register(tabID: tab.id, taskID: task.id, status: blocks.hasContent ? .working : .awaitingReply)

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
        ChildSessionCoordinator.shared.attach(to: session, task: task, tab: tab)
        session.start(
            workingDirectory: workingDirectory,
            permissionMode: resolvedPermissionMode(
                tab: tab.permissionMode,
                task: task.permissionMode,
                appDefault: AppSettings.shared.resolvedDefaultPermissionMode
            ),
            resumeSessionID: resumeSessionID,
            settingsPath: settingsPath,
            model: tab.model ?? AppSettings.shared.defaultClaudeModel.pinnedModel,
            isModelExplicitlyChosen: tab.isModelUserChosen,
            effort: effort,
            environment: HeadlessCommand.environment
                .merging(LoginShellCommand.plumeEnvironment(taskID: task.id, tabID: tab.id)) { current, _ in current },
            fork: fork,
            sessionID: sessionID,
            addDirectories: AdditionalDirectories.list(
                tab.additionalDirectories + ChildSessionCoordinator.launchDirectories(for: tab),
                excluding: workingDirectory
            )
        )
        session.onAdoptDirectories = { [weak tab] paths in
            guard let tab else { return }
            AdditionalDirectoryStore.adopt(paths, into: tab)
        }
        session.onGrantDirectories = { [weak tab] paths in
            guard let tab else { return }
            AdditionalDirectoryStore.grant(paths, to: tab)
        }
        session.declinedDirectories = { [weak tab] in tab?.removedAdditionalDirectories ?? [] }
        if blocks.hasContent {
            session.submit(blocks: blocks)
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
        guard SurfaceManager.shared.existingSession(for: tab.id) == nil else { return }
        guard !AgentSessionManager.shared.isCodexThreadOwnedElsewhere(resumeSessionID, by: tab.id) else {
            Log.agent.error("Refusing to resume a Codex thread already open in another Plume tab")
            StatusEngine.shared.setStatus(.error, taskID: task.id, tabID: tab.id)
            return
        }
        let socket: String
        do {
            socket = try CodexTerminalMonitor.shared.start(
                tabID: tab.id, taskID: task.id, directory: TabDirectoryStore.shared.directory(for: tab),
                resumeThreadID: resumeSessionID
            ) { [tabID = tab.id] id in
                AgentEventMonitor.shared.onSessionIDDiscovered?(tabID, id)
            }
        } catch {
            StatusEngine.shared.setStatus(.error, taskID: task.id, tabID: tab.id)
            return
        }
        let provider = CodexProvider(remoteSocket: socket)
        let launch = provider.launchCommand(
            firstMessage: message,
            resumeSessionID: resumeSessionID,
            taskID: nil,
            tabID: nil,
            permissionMode: nil
        )
        StatusEngine.shared.register(tabID: tab.id, taskID: task.id, status: .notStarted)
        SurfaceManager.shared.session(
            for: tab.id,
            options: TerminalSurfaceOptions(
                workingDirectory: TabDirectoryStore.shared.directory(for: tab),
                envVars: launch.environment
                    .merging(LoginShellCommand.plumeEnvironment(taskID: task.id, tabID: tab.id)) { current, _ in current },
                command: launch.command
            )
        )
    }

    private static func launchCodexHeadless(
        blocks: [UserContentBlock],
        task: WorkTask,
        tab: TaskTab,
        resumeSessionID: String?
    ) {
        StatusEngine.shared.register(tabID: tab.id, taskID: task.id, status: .working)

        let existing = AgentSessionManager.shared.session(
            for: tab.id,
            taskID: task.id,
            provider: .codex,
            initialEffort: tab.isEffortUserChosen ? tab.effort : nil
        )
        guard let session = existing as? CodexSession else {
            Log.agent.error("Tab \(tab.id, privacy: .public) already holds another CLI's session")
            return
        }
        guard AgentSessionManager.shared.claimCodexThread(resumeSessionID, for: tab.id) else {
            session.failToLaunch(reason: "This Codex conversation is already open in another \(AppIdentity.displayName) tab. Continue there, or close that tab before resuming here.")
            return
        }
        session.start(
            workingDirectory: TabDirectoryStore.shared.directory(for: tab),
            resumeThreadID: resumeSessionID,
            model: resumeSessionID == nil || tab.isModelUserChosen ? tab.model : nil,
            collaborationMode: tab.codexCollaborationMode,
            permissionProfile: tab.permissionModeRaw,
            defaultPermissionProfile: AppSettings.shared.defaultCodexPermissionProfile.id,
            // One app-server runs every headless Codex tab, so the tab's own
            // IDs ride on its thread rather than on the process.
            environment: LoginShellCommand.sharedPlumeEnvironment(),
            threadEnvironment: LoginShellCommand.plumeEnvironment(taskID: task.id, tabID: tab.id)
        )
        if blocks.hasContent {
            session.submit(blocks: blocks)
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

        let workingDirectory = claudeLaunchDirectory(for: tab, resumeSessionID: resumeSessionID)
        let provider = ClaudeCodeProvider(
            settingsPath: settingsPath,
            additionalDirectories: AdditionalDirectories.list(tab.additionalDirectories, excluding: workingDirectory)
        )
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
                workingDirectory: workingDirectory,
                envVars: launch.environment
                    .merging(LoginShellCommand.plumeEnvironment(taskID: task.id, tabID: tab.id)) { current, _ in current },
                command: launch.command
            )
        )
    }

    /// A resume runs from where the session was launched, not from where the
    /// tab is now. Claude Code refuses to resume from inside a worktree the
    /// session entered with `EnterWorktree`, and moves the session back into
    /// that worktree itself.
    static func claudeLaunchDirectory(for tab: TaskTab, resumeSessionID: String?) -> String? {
        let current = TabDirectoryStore.shared.directory(for: tab)
        guard let resumeSessionID, !resumeSessionID.isEmpty else { return current }
        let recordedTranscript = tab.sessionJSONLPath.flatMap {
            SessionJSONLReader.hasContent(atPath: $0) ? $0 : nil
        }
        let transcript = recordedTranscript ?? SessionJSONLReader.locateTranscript(sessionID: resumeSessionID)
        return transcript.flatMap(SessionJSONLReader.launchDirectory(atPath:)) ?? current
    }
}
