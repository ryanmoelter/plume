import Foundation
import os
import SwiftData

/// Runs child sessions: the sessions an agent in a headless Claude tab starts
/// in tabs beside its own, and the notes that pass between them.
///
/// A session's id, to the model, is its tab's UUID. Only
/// `TaskTab.parentTabIDRaw` is persisted; everything else here lives in
/// memory, so after a relaunch a child still reports to its parent but the
/// held notes are gone. `docs/child-sessions.md` is the reference.
@MainActor
final class ChildSessionCoordinator {
    static let shared = ChildSessionCoordinator()

    private var policies: [UUID: ChildSessionWakePolicy] = [:]
    private var childNames: [UUID: String] = [:]
    private var silentChildren: Set<UUID> = []

    // MARK: - Wiring a session

    /// Serves Plume's tools to `session` and watches its turns. Called for
    /// every headless Claude launch, before `start`.
    func attach(to session: HeadlessSession, task: WorkTask, tab: TaskTab) {
        let tabID = tab.id
        session.mcpServer = PlumeMCPServer(
            role: { [weak tab] in
                guard let tab, tab.isChildSession else { return .parent }
                return .child(parentID: tab.parentTabIDRaw)
            },
            callTool: { [weak self, weak tab] call in
                guard let self, let tab, tab.isLive else {
                    return .failure("This session's tab is closed.")
                }
                return await self.handle(call, from: tab)
            }
        )
        session.onTurnFinished = { [weak self, weak tab] outcome in
            guard let self, let tab, tab.isLive else { return }
            self.turnFinished(in: tab, outcome: outcome)
        }
        session.userMessagePreamble = { [weak self] in
            self?.takePreamble(forParent: tabID)
        }
    }

    func tabForgotten(_ tabID: UUID) {
        policies.removeValue(forKey: tabID)
        childNames.removeValue(forKey: tabID)
        silentChildren.remove(tabID)
    }

    /// Selects the tab of the session a chat row names. False when no open
    /// window holds it.
    @discardableResult
    func select(sessionID: String) -> Bool {
        guard let id = UUID(uuidString: sessionID),
              let task = CLICommandHandler.shared.currentTask(ofTab: id)?.task,
              let tab = task.liveTabs.first(where: { $0.id == id })
        else { return false }
        TaskStore.selectTab(tab, in: task)
        return true
    }

    nonisolated static func sessionID(of tab: TaskTab) -> String { tab.id.uuidString }

    // MARK: - Tools

    private func handle(_ call: PlumeMCPServer.ToolCall, from tab: TaskTab) async -> PlumeMCPServer.ToolResult {
        let result: Result<String, ChildSessionError>
        switch call.tool {
        case .startSession:
            switch StartSessionRequest.parse(call.arguments) {
            case .success(let request): result = await startSession(request, from: tab)
            case .failure(let error): result = .failure(error)
            }
        case .sendMessage:
            result = sendMessage(call.arguments, from: tab)
        }
        switch result {
        case .success(let text): return .success(text)
        case .failure(let error): return .failure(error.message)
        }
    }

    /// Opens the child's tab and launches it with its brief.
    func startSession(_ request: StartSessionRequest, from parent: TaskTab) async -> Result<String, ChildSessionError> {
        guard request.initiation == .userAsked else { return .failure(.proposalsUnsupported) }
        guard !parent.isChildSession else { return .failure(.failed("This session cannot start sessions of its own.")) }
        guard let task = parent.task, let context = parent.modelContext else {
            return .failure(.failed("This session's task is gone."))
        }
        let live = LiveSettings(of: parent)
        let mode: PermissionMode
        switch ChildSessionPermissions.mode(
            requested: request.permissionMode,
            parent: live.permissionMode,
            showsBypassPermissions: AppSettings.shared.showsBypassPermissions
        ) {
        case .success(let resolved): mode = resolved
        case .failure(let error): return .failure(error)
        }
        let parentSessionID = parent.agentSessionID ?? ""
        if request.context == .fork, parentSessionID.isEmpty {
            return .failure(.failed("This conversation has no session id yet, so it cannot be forked."))
        }

        let parentIsOpen = { parent.isLive && parent.task === task }
        guard parentIsOpen() else { return .failure(.parentClosed) }
        let worktree: ChildSessionWorkspace.Worktree?
        switch await ChildSessionWorkspace.worktree(for: request, parent: parent) {
        case .success(let made): worktree = made
        case .failure(let error): return .failure(error)
        }
        // Cutting the worktree took a while, and the parent may have closed meanwhile.
        guard parentIsOpen() else {
            if let worktree { await ChildSessionWorkspace.remove(worktree) }
            return .failure(.parentClosed)
        }

        let child = TaskStore.addChildTab(to: task, parent: parent, in: context)
        TabLaunchChoices(parent).apply(to: child)
        child.transport = .headless
        child.providerID = AgentProviderKind.claudeCode.rawValue
        if let model = live.model { child.model = model }
        if let effort = live.effort { child.effort = effort }
        if let model = request.model {
            child.model = model
            child.isModelUserChosen = true
        }
        if let effort = request.effort {
            child.effort = effort
            child.isEffortUserChosen = true
        }
        child.permissionMode = mode

        ChildSessionWorkspace.apply(worktree, to: child, parent: parent)

        let notes = AppPaths.sideSessionNotesDirectory(parentTabID: parent.id)
        try? FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        var directories = parent.additionalDirectories
        if let worktree, request.context == .fork { directories.append(worktree.path) }
        directories.append(notes.path)
        child.additionalDirectories = AdditionalDirectories.list(directories, excluding: nil)

        child.title = request.title
        child.titleSource = .custom
        TitleStore.shared.setTitle(request.title, forTab: child.id, source: .custom)
        childNames[child.id] = request.name
        if !request.wakeWhenDone { silentChildren.insert(child.id) }

        let isFork = request.context == .fork
        let newSessionID = UUID().uuidString.lowercased()
        child.agentSessionID = newSessionID
        // A fork launches where the parent's transcript is, whatever folder
        // the tab records, and the CLI writes the new transcript beside it.
        let launchDirectory = isFork
            ? AgentLauncher.claudeLaunchDirectory(for: parent, resumeSessionID: parentSessionID)
            : TabDirectoryStore.shared.directory(for: child)
        if let directory = launchDirectory {
            child.sessionJSONLPath = SessionJSONLReader.resolvedTranscriptPath(
                workingDirectory: directory, sessionID: newSessionID
            )
        }

        var prompt = request.prompt
        if let worktree, request.context == .fork {
            prompt += "\n\n" + ChildSessionFormats.worktreeNote(path: worktree.workingDirectory, branch: worktree.branch)
        }
        let brief = ChildSessionFormats.firstMessage(
            prompt: prompt, background: request.background, notesFolder: notes.path
        )
        PendingFirstMessageStore.shared.set(OptimisticFirstMessage(text: brief), forTab: child.id)

        AgentLauncher.launch(
            blocks: [],
            task: task,
            tab: child,
            resumeSessionID: isFork ? parentSessionID : nil,
            fork: isFork ? HeadlessCommand.Fork(newSessionID: newSessionID, cutAfterMessageUUID: nil) : nil,
            sessionID: isFork ? nil : newSessionID,
            effort: child.isEffortUserChosen ? child.effort : nil
        )
        let session = AgentSessionManager.shared.existingSession(for: child.id) as? HeadlessSession
        guard let session, !session.hasExited else {
            let reason = session.map(Self.launchFailure) ?? "no session was created"
            TaskStore.closeTab(child, in: context)
            if let worktree { await ChildSessionWorkspace.remove(worktree) }
            return .failure(.failed("The session could not start: \(reason)"))
        }
        if let worktree { ChildSessionWorkspace.recordOwnership(of: worktree, in: task) }
        session.submitFromHost(blocks: [.text(brief)])

        return .success(ChildSessionFormats.started(
            title: request.title,
            sessionID: Self.sessionID(of: child),
            name: request.name ?? WorkspaceProvisioner.slugify(request.title)
        ))
    }

    private static func launchFailure(of session: HeadlessSession) -> String {
        if let failure = session.startFailure {
            return [failure.title, failure.detail].compactMap { $0 }.joined(separator: ": ")
        }
        return session.lastError ?? "claude exited at launch"
    }

    private func sendMessage(_ arguments: [String: JSONValue], from sender: TaskTab) -> Result<String, ChildSessionError> {
        guard let to = arguments["to"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !to.isEmpty else {
            return .failure(.invalid("to is required"))
        }
        guard let message = arguments["message"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !message.isEmpty
        else { return .failure(.invalid("message is required")) }
        guard let task = sender.task else { return .failure(.failed("This session's task is gone.")) }

        let parent = parent(of: sender)
        if sender.isChildSession, parent == nil, to == "parent" || to.caseInsensitiveCompare(sender.parentTabIDRaw) == .orderedSame {
            return .failure(.failed("The session that started this one is closed, so nothing can reach it."))
        }
        let target: TaskTab
        if to == "parent", let parent {
            target = parent
        } else if let id = UUID(uuidString: to), let tab = task.liveTabs.first(where: { $0.id == id }) {
            target = tab
        } else {
            return .failure(.unknownSession(to))
        }

        if let parent, target.id == parent.id {
            let note = ChildSessionFormats.messageFromChildNote(child: participant(sender), text: message)
            deliver(.init(childID: sender.id, text: note), toParent: parent, wakes: true)
            return .success(ChildSessionFormats.delivered(to: TitleStore.shared.chipTitle(for: parent), queued: isWorking(parent)))
        }
        guard target.parentTabID == sender.id else { return .failure(.notRelated(to)) }
        let note = ChildSessionFormats.messageFromParentNote(parent: participant(sender), text: message)
        let queued = isWorking(target)
        guard submitFromHost(note, to: target, in: task) else {
            return .failure(.failed("Session \(to) could not be reached."))
        }
        return .success(ChildSessionFormats.delivered(to: TitleStore.shared.chipTitle(for: target), queued: queued))
    }

    // MARK: - Notes

    private func turnFinished(in tab: TaskTab, outcome: AgentTurnOutcome) {
        if let parent = parent(of: tab) {
            let note = ChildSessionFormats.turnFinishedNote(
                child: participant(tab), text: ChildSessionFormats.reportText(of: outcome)
            )
            let wakes = outcome.isHostDriven && !outcome.wasInterrupted && !silentChildren.contains(tab.id)
            deliver(.init(childID: tab.id, text: note), toParent: parent, wakes: wakes)
        }
        guard var policy = policies[tab.id] else { return }
        let due = policy.parentTurnFinished(interrupted: outcome.wasInterrupted, parentIsWorking: isWorking(tab))
        policies[tab.id] = policy
        if let due { wake(tab, with: due) }
    }

    private func deliver(_ note: ChildSessionWakePolicy.Note, toParent parent: TaskTab, wakes: Bool) {
        var policy = policies[parent.id] ?? ChildSessionWakePolicy()
        let due = policy.noteArrived(note, wakes: wakes, parentIsWorking: isWorking(parent))
        policies[parent.id] = policy
        if let due { wake(parent, with: due) }
    }

    private func wake(_ parent: TaskTab, with notes: [ChildSessionWakePolicy.Note]) {
        guard let task = parent.task, !notes.isEmpty else { return }
        if !submitFromHost(Self.joined(notes), to: parent, in: task) {
            Log.agent.error("Could not deliver child-session notes to tab \(parent.id, privacy: .public)")
        }
    }

    private func takePreamble(forParent tabID: UUID) -> String? {
        guard var policy = policies[tabID] else { return nil }
        let notes = policy.userWillSend()
        policies[tabID] = policy
        return notes.isEmpty ? nil : Self.joined(notes)
    }

    nonisolated static func joined(_ notes: [ChildSessionWakePolicy.Note]) -> String {
        notes.map(\.text).joined(separator: "\n\n")
    }

    // MARK: - Reaching a tab's session

    /// Submits to the tab's running session, or resumes its conversation
    /// first. False when the tab has no conversation to resume.
    @discardableResult
    private func submitFromHost(_ text: String, to tab: TaskTab, in task: WorkTask) -> Bool {
        if let session = AgentSessionManager.shared.existingSession(for: tab.id) as? HeadlessSession, !session.hasExited {
            session.submitFromHost(blocks: [.text(text)])
            return true
        }
        guard tab.provider == .claudeCode, tab.transport == .headless,
              let sessionID = tab.agentSessionID, !sessionID.isEmpty
        else { return false }
        AgentSessionManager.shared.closeSession(for: tab.id)
        AgentLauncher.launch(blocks: [], task: task, tab: tab, resumeSessionID: sessionID)
        guard let session = AgentSessionManager.shared.existingSession(for: tab.id) as? HeadlessSession else { return false }
        session.submitFromHost(blocks: [.text(text)])
        return true
    }

    private func isWorking(_ tab: TaskTab) -> Bool {
        (AgentSessionManager.shared.existingSession(for: tab.id) as? HeadlessSession)?.isWorking ?? false
    }

    /// The live tab that started `tab`, in the same task.
    func parent(of tab: TaskTab) -> TaskTab? {
        guard let parentID = tab.parentTabID, parentID != tab.id else { return nil }
        return tab.task?.liveTabs.first { $0.id == parentID }
    }

    /// What the parent's session runs on now, or what its tab records when
    /// no session is running.
    private struct LiveSettings {
        let permissionMode: PermissionMode
        let model: AgentModel?
        let effort: AgentEffort?

        init(of tab: TaskTab) {
            let session = AgentSessionManager.shared.existingSession(for: tab.id) as? HeadlessSession
            let running = session.flatMap { $0.hasExited ? nil : $0 }
            permissionMode = running?.permissionMode ?? HeadlessCommand.launchPermissionMode(
                AgentLauncher.resolvedPermissionMode(
                    tab: tab.permissionMode,
                    task: tab.task?.permissionMode,
                    appDefault: AppSettings.shared.resolvedDefaultPermissionMode
                )
            )
            model = running?.model ?? tab.model
            effort = running?.effort ?? tab.effort
        }
    }

    private func participant(_ tab: TaskTab) -> ChildSessionFormats.Participant {
        ChildSessionFormats.Participant(
            sessionID: Self.sessionID(of: tab),
            title: TitleStore.shared.chipTitle(for: tab),
            name: childNames[tab.id]
        )
    }

    #if DEBUG
    /// Reports a turn as if `child` had just finished one, for the control
    /// server.
    func simulateTurnFinished(in child: TaskTab, text: String, hostDriven: Bool) {
        turnFinished(in: child, outcome: AgentTurnOutcome(
            text: text, isError: false, wasInterrupted: false, isHostDriven: hostDriven
        ))
    }
    #endif
}

/// Where a child session works.
nonisolated enum ChildSessionWorkspace {
    struct Worktree: Equatable {
        let path: String
        let repository: String
        let branch: String
        /// The folder the child works in: the same subfolder of the worktree
        /// that the parent works in, when the worktree has it.
        var workingDirectory: String

        init(path: String, repository: String, branch: String, workingDirectory: String? = nil) {
            self.path = path
            self.repository = repository
            self.branch = branch
            self.workingDirectory = workingDirectory ?? path
        }
    }

    /// An unspecified choice follows the parent: a worktree when it works in one.
    static func usesWorktree(requested: Bool?, parentIsWorktree: Bool) -> Bool {
        requested ?? parentIsWorktree
    }

    /// Puts `child` in its worktree, or in the parent's folder.
    @MainActor
    static func apply(_ worktree: Worktree?, to child: TaskTab, parent: TaskTab) {
        guard let worktree else {
            child.workspace = TabDirectoryStore.shared.currentWorkspace(of: parent)
            return
        }
        child.workspace = TabWorkspace(
            kind: .worktree, directory: worktree.workingDirectory, repoPath: worktree.repository, branchName: worktree.branch
        )
    }

    /// Once the child has launched, so a failed start leaves the task owning
    /// nothing.
    @MainActor
    static func recordOwnership(of worktree: Worktree, in task: WorkTask) {
        task.recordOwnedWorktree(OwnedWorktree(path: worktree.path, repoPath: worktree.repository, branch: worktree.branch))
    }

    /// Removes a worktree this call cut, with its branch, which nothing else
    /// has used yet.
    static func remove(_ worktree: Worktree) async {
        do {
            try await GitService.shared.removeWorktree(
                repository: worktree.repository, path: worktree.path, branch: worktree.branch, deleteBranch: true
            )
        } catch {
            Log.agent.error("Could not remove the child session's worktree \(worktree.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// `directory` relative to `checkoutRoot`, or nil when it is the root or
    /// lies outside it.
    static func subfolder(of directory: String, in checkoutRoot: String) -> String? {
        let root = (checkoutRoot as NSString).standardizingPath
        let path = (directory as NSString).standardizingPath
        guard path.hasPrefix(root + "/") else { return nil }
        return String(path.dropFirst(root.count + 1))
    }

    /// The child's own worktree, cut from the parent's HEAD, or nil when it
    /// shares the parent's folder.
    @MainActor
    static func worktree(for request: StartSessionRequest, parent: TaskTab) async -> Result<Worktree?, ChildSessionError> {
        guard let directory = TabDirectoryStore.shared.directory(for: parent) else {
            return request.useWorktree == true ? .failure(.failed("This session has no folder to cut a worktree from.")) : .success(nil)
        }
        let facts = await GitService.shared.checkoutFacts(containing: directory)
        guard usesWorktree(requested: request.useWorktree, parentIsWorktree: facts?.isWorktree ?? false) else {
            return .success(nil)
        }
        guard let facts else { return .failure(.failed("\(directory) is not in a git repository, so it has no worktree to cut.")) }
        // One `rev-parse` of the live folder names both the repository and
        // the checkout whose HEAD the worktree starts from.
        let repository = ProjectRoot.repositoryDirectory(forRoot: facts.projectRoot)
        let prefix = await GitService.shared.configuredBranchPrefix(
            in: repository, configuration: AppSettings.shared.projectsConfiguration
        ) ?? WorkspaceProvisioner.defaultBranchPrefix
        let branch = WorkspaceProvisioner.suggestedBranchName(for: request.name ?? request.title, prefix: prefix)
        let head = await GitService.shared.headCommit(in: facts.checkoutRoot)
        do {
            let path = try await GitService.shared.createWorktree(
                repository: repository,
                branch: branch,
                basePath: AppSettings.shared.worktreeBasePath,
                startPoint: head
            )
            var worktree = Worktree(path: path, repository: repository, branch: branch)
            if let subfolder = subfolder(of: directory, in: facts.checkoutRoot) {
                let nested = (path as NSString).appendingPathComponent(subfolder)
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: nested, isDirectory: &isDirectory), isDirectory.boolValue {
                    worktree.workingDirectory = nested
                }
            }
            return .success(worktree)
        } catch {
            return .failure(.failed("Could not create a worktree: \(error.localizedDescription)"))
        }
    }
}
