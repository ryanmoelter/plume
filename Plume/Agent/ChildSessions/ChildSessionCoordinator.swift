import Foundation
import os
import SwiftData

/// Runs child sessions: the sessions an agent in a headless Claude tab starts
/// in tabs beside its own, and the notes that pass between them.
///
/// A session's id, to the model, is its tab's UUID. Only
/// `TaskTab.parentTabIDRaw` and a parent's proposals are persisted;
/// everything else here lives in memory, so after a relaunch a child still
/// reports to its parent but the held notes are gone. `docs/child-sessions.md` is the reference.
@MainActor
final class ChildSessionCoordinator {
    static let shared = ChildSessionCoordinator()

    private var policies: [UUID: ChildSessionWakePolicy] = [:]
    private var childNames: [UUID: String] = [:]
    private var silentChildren: Set<UUID> = []
    private var launchModes: [UUID: PermissionMode] = [:]
    /// Per parent, the wake check due when a working child reaches
    /// `ChildSessionWakePolicy.workingLimit`.
    private var limitChecks: [UUID: Task<Void, Never>] = [:]

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
        session.permissionCeiling = { [weak self, weak tab] in
            guard let self, let tab, tab.isChildSession else { return nil }
            return self.permissionCeiling(forChild: tab)
        }
        session.onHostMessagesReturned = { [weak self, weak tab] messages in
            guard let self, let tab, tab.isLive else { return }
            self.hostMessagesReturned(messages, by: tab)
        }
    }

    func tabForgotten(_ tabID: UUID) {
        policies.removeValue(forKey: tabID)
        childNames.removeValue(forKey: tabID)
        silentChildren.remove(tabID)
        launchModes.removeValue(forKey: tabID)
        limitChecks.removeValue(forKey: tabID)?.cancel()
        ChildSessionProposalActivity.shared.forget(tabID)
        ChildSessionProposalStoreCache.shared.forget(tabID)
    }

    /// A parent's message still unread in a closing child goes back to the
    /// parent as a held note, and a closing child stops holding the parent's
    /// wakes. Call before the child's session is discarded.
    func childClosing(_ child: TaskTab) {
        guard let parent = parent(of: child) else { return }
        if let session = AgentSessionManager.shared.existingSession(for: child.id) as? HeadlessSession {
            for case .fromParent(let text)? in session.unreadHostMessages.map(\.origin) {
                let note = ChildSessionFormats.messageRemovedNote(child: participant(child), text: text, .closed)
                hold([.init(childID: child.id, text: note, kind: .message)], for: parent)
            }
        }
        recheckWake(of: parent, excluding: child.id)
    }

    private func permissionCeiling(forChild child: TaskTab) -> PermissionMode {
        ChildSessionPermissions.ceiling(
            parent: parent(of: child).map { LiveSettings(of: $0).permissionMode },
            launchedWith: launchModes[child.id] ?? LiveSettings.recordedMode(of: child),
            showsBypassPermissions: AppSettings.shared.showsBypassPermissions
        )
    }

    /// The highest mode the child's own picker offers: the parent's live
    /// mode while the parent is open, and no limit once it is gone.
    func pickerCeiling(forChild child: TaskTab) -> PermissionMode? {
        guard let parent = parent(of: child) else { return nil }
        return ChildSessionPermissions.ceiling(
            parent: LiveSettings(of: parent).permissionMode,
            launchedWith: LiveSettings.recordedMode(of: child),
            showsBypassPermissions: AppSettings.shared.showsBypassPermissions
        )
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

    /// Folders a launch adds for `tab`'s role: a parent with open children
    /// gets their notes folder. A running parent learns the folder from the
    /// `start_session` result instead of restarting.
    static func launchDirectories(for tab: TaskTab) -> [String] {
        let id = tab.id
        guard tab.task?.liveTabs.contains(where: { $0.parentTabID == id }) == true else { return [] }
        return [AppPaths.sideSessionNotesDirectory(parentTabID: id).path]
    }

    // MARK: - Tools

    private func handle(_ call: PlumeMCPServer.ToolCall, from tab: TaskTab) async -> PlumeMCPServer.ToolResult {
        let result: Result<String, ChildSessionError>
        switch call.tool {
        case .startSession:
            switch StartSessionCall.parse(call.arguments) {
            case .success(.start(let request)): result = await startSession(request, from: tab)
            case .success(.propose(let request)):
                result = propose(request, from: tab).map { ChildSessionFormats.proposed(title: $0.title, taskID: $0.id) }
            case .success(.startProposal(let id, let wakeWhenDone, let settings)):
                result = await startProposal(id, from: tab, wakeWhenDone: wakeWhenDone, settings: settings, byUser: false)
            case .failure(let error): result = .failure(error)
            }
        case .sendMessage:
            result = sendMessage(call.arguments, from: tab)
        case .dismissTask:
            guard let id = call.arguments["task_id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else {
                result = .failure(.invalid("task_id is required"))
                break
            }
            let reason = call.arguments["reason"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            result = dismissProposal(id, reason: reason.flatMap { $0.isEmpty ? nil : $0 }, from: tab, byUser: false)
        }
        switch result {
        case .success(let text): return .success(text)
        case .failure(let error): return .failure(error.message)
        }
    }

    /// Opens the child's tab and launches it with its brief.
    func startSession(_ request: StartSessionRequest, from parent: TaskTab) async -> Result<String, ChildSessionError> {
        switch await launchChild(request, from: parent) {
        case .success(let child): .success(startedText(for: child, request: request, parent: parent))
        case .failure(let error): .failure(error)
        }
    }

    private func startedText(for child: TaskTab, request: StartSessionRequest, parent: TaskTab) -> String {
        let started = ChildSessionFormats.started(
            title: request.title,
            sessionID: Self.sessionID(of: child),
            name: childNames[child.id] ?? WorkspaceProvisioner.slugify(request.title),
            notesFolder: AppPaths.sideSessionNotesDirectory(parentTabID: parent.id).path
        )
        return request.ignoresWorktreeRequest ? started + " " + ChildSessionFormats.forkWorktreeIgnored : started
    }

    /// `proposalID` names the proposal this launch starts. It is recorded as
    /// started in the same step that opens the child's tab, so no later
    /// failure or crash can let it start twice.
    private func launchChild(
        _ request: StartSessionRequest, from parent: TaskTab, proposalID: String? = nil
    ) async -> Result<TaskTab, ChildSessionError> {
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

        let name = request.name ?? WorkspaceProvisioner.slugify(request.title)
        let child = TaskStore.addChildTab(to: task, parent: parent, in: context)
        if let proposalID {
            let recorded = withProposals(of: parent, prunes: false) {
                $0.markStarted(id: proposalID, sessionID: Self.sessionID(of: child), name: name, now: .now)
            }
            if !recorded {
                Log.agent.error("Proposal \(proposalID, privacy: .public) vanished while it started")
            }
        }
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
        launchModes[child.id] = mode

        ChildSessionWorkspace.apply(worktree, to: child, parent: parent)

        let notes = AppPaths.sideSessionNotesDirectory(parentTabID: parent.id)
        try? FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        var directories = parent.additionalDirectories
        directories.append(notes.path)
        child.additionalDirectories = AdditionalDirectories.list(directories, excluding: nil)

        child.title = request.title
        child.titleSource = .custom
        TitleStore.shared.setTitle(request.title, forTab: child.id, source: .custom)
        childNames[child.id] = name
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

        let brief = ChildSessionFormats.firstMessage(
            prompt: request.prompt, background: request.background, notesFolder: notes.path
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
            if let proposalID { withProposals(of: parent, prunes: false) { $0.reopen(id: proposalID) } }
            if let worktree { await ChildSessionWorkspace.remove(worktree) }
            return .failure(.failed("The session could not start: \(reason)"))
        }
        if let worktree { ChildSessionWorkspace.recordOwnership(of: worktree, in: task) }
        session.submitFromHost(blocks: [.text(brief)], display: [.text(request.prompt)], origin: .fromParent(text: request.prompt))
        return .success(child)
    }

    // MARK: - Proposals

    /// Records a card for the user to start, and starts nothing.
    func propose(_ request: StartSessionRequest, from parent: TaskTab, now: Date = .now) -> Result<ChildSessionProposal, ChildSessionError> {
        guard !parent.isChildSession else { return .failure(.failed("This session cannot start sessions of its own.")) }
        guard ChildSessionProposalStore(json: parent.childProposalsJSON).isWritable else {
            return .failure(.failed("This session's stored proposals could not be read, so no new one can be recorded."))
        }
        return .success(withProposals(of: parent, now: now) { store in
            var id = ChildSessionProposalStore.makeID()
            while store.proposal(id: id) != nil { id = ChildSessionProposalStore.makeID() }
            let proposal = ChildSessionProposal(id: id, request: request, createdAt: now)
            store.add(proposal)
            return proposal
        })
    }

    /// Starts a pending proposal with the brief and settings it was proposed
    /// with, refusing repeated `settings` that differ from them. A start the
    /// user made from the card also tells the parent, as a note that wakes it
    /// unless the proposal asked not to be woken, and a refusal shows on the
    /// card.
    func startProposal(
        _ id: String,
        from parent: TaskTab,
        wakeWhenDone: Bool? = nil,
        settings: [String: JSONValue] = [:],
        byUser: Bool,
        now: Date = .now
    ) async -> Result<String, ChildSessionError> {
        let activity = ChildSessionProposalActivity.shared
        guard !activity.isStarting(id, in: parent.id) else { return .failure(.proposal(.starting(id))) }
        func refuse(_ error: ChildSessionError) -> Result<String, ChildSessionError> {
            if byUser { activity.fail(id, in: parent.id, Self.cardFailure(error)) }
            return .failure(error)
        }
        let pending = withProposals(of: parent, now: now) { $0.pending(id: id, now: now) }
        let proposal: ChildSessionProposal
        switch pending {
        case .success(let found): proposal = found
        case .failure(let error): return refuse(.proposal(error))
        }
        if let conflict = proposal.conflict(with: settings) { return refuse(conflict) }
        let request: StartSessionRequest
        switch proposal.request(wakeWhenDone: wakeWhenDone) {
        case .success(let parsed): request = parsed
        case .failure(let error): return refuse(error)
        }

        activity.begin(id, in: parent.id)
        let child: TaskTab
        switch await launchChild(request, from: parent, proposalID: id) {
        case .success(let launched):
            activity.end(id, in: parent.id, failure: nil)
            child = launched
        case .failure(let error):
            activity.end(id, in: parent.id, failure: byUser ? Self.cardFailure(error) : nil)
            return .failure(error)
        }

        if byUser {
            let note = ChildSessionFormats.proposalStartedNote(taskID: id, title: proposal.title, child: participant(child))
            deliver(.init(childID: child.id, text: note, kind: .message), toParent: parent, wakes: request.wakeWhenDone)
        }
        return .success(startedText(for: child, request: request, parent: parent))
    }

    /// Withdraws a pending proposal. The user's own dismissal from the card
    /// tells the parent nothing, as in Desktop.
    func dismissProposal(
        _ id: String, reason: String?, from parent: TaskTab, byUser: Bool, now: Date = .now
    ) -> Result<String, ChildSessionError> {
        guard !ChildSessionProposalActivity.shared.isStarting(id, in: parent.id) else {
            return .failure(.proposal(.starting(id)))
        }
        let dismissed = withProposals(of: parent, now: now) {
            $0.dismiss(id: id, reason: reason, byUser: byUser, now: now)
        }
        switch dismissed {
        case .success(let proposal):
            ChildSessionProposalActivity.shared.clearFailure(of: id, in: parent.id)
            return .success(ChildSessionFormats.proposalDismissed(title: proposal.title, taskID: id))
        case .failure(let error):
            return .failure(.proposal(error))
        }
    }

    /// What a card says when the user's start is refused: the expiry in the
    /// user's terms, anything else as the agent would read it.
    private static func cardFailure(_ error: ChildSessionError) -> ChildSessionProposalActivity.Failure {
        if case .proposal(.expired) = error { return .init(text: "This proposal expired: proposals last 7 days.", state: .expired) }
        return .init(text: error.message, state: .pending)
    }

    /// Runs `body` on the tab's proposals, then prunes and saves them.
    @discardableResult
    func withProposals<T>(
        of tab: TaskTab, now: Date = .now, prunes: Bool = true, _ body: (inout ChildSessionProposalStore) -> T
    ) -> T {
        var store = ChildSessionProposalStore(json: tab.childProposalsJSON)
        let result = body(&store)
        if prunes { store.prune(now: now) }
        let json = store.json
        if tab.childProposalsJSON != json { tab.childProposalsJSON = json }
        return result
    }

    /// The tab whose proposals `tab`'s chat shows: a child's transcript
    /// carries its parent's. Nil when that parent has closed.
    static func proposalOwner(of tab: TaskTab) -> TaskTab? {
        guard tab.isChildSession else { return tab }
        return tab.parentTabID.flatMap { id in tab.task?.liveTabs.first { $0.id == id } }
    }

    /// The tab's proposals as they read at `now`, without saving anything.
    func proposals(of tab: TaskTab, now: Date = .now) -> ChildSessionProposalStore {
        var store = ChildSessionProposalStore(json: tab.childProposalsJSON)
        store.prune(now: now)
        return store
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
            let text = ChildSessionFormats.messageFromChildNote(child: participant(sender), text: message)
            let note = ChildSessionWakePolicy.Note(childID: sender.id, text: text, kind: .message)
            deliver(note, toParent: parent, wakes: true)
            let policy = policies[parent.id]
            let delivery: ChildSessionFormats.Delivery = if policy?.waitsForUser(note) == true {
                .heldForUser
            } else if policy?.waking.contains(note) != true {
                .sent
            } else {
                activity(of: parent).childIsWorking ? .awaitingSessions : .queued
            }
            return .success(ChildSessionFormats.delivered(to: TitleStore.shared.chipTitle(for: parent), delivery))
        }
        guard target.parentTabID == sender.id else { return .failure(.notRelated(to)) }
        let note = ChildSessionFormats.messageFromParentNote(parent: participant(sender), text: message)
        let queued = isWorking(target)
        guard submitFromHost(note, display: message, origin: .fromParent(text: message), to: target, in: task) else {
            return .failure(.failed("Session \(to) could not be reached."))
        }
        return .success(ChildSessionFormats.delivered(to: TitleStore.shared.chipTitle(for: target), queued ? .queued : .sent))
    }

    // MARK: - Notes

    private func turnFinished(in tab: TaskTab, outcome: AgentTurnOutcome) {
        if let parent = parent(of: tab) {
            let note = ChildSessionFormats.turnFinishedNote(
                child: participant(tab), text: ChildSessionFormats.reportText(of: outcome)
            )
            let wakes = !outcome.wasInterrupted && !silentChildren.contains(tab.id)
            deliver(.init(childID: tab.id, text: note), toParent: parent, wakes: wakes)
        }
        guard var policy = policies[tab.id] else { return }
        // The user's queued message already answered the interrupt.
        let interrupted = outcome.wasInterrupted && !outcome.userTurnFollows
        let due = policy.parentTurnFinished(interrupted: interrupted, activity(of: tab))
        policies[tab.id] = policy
        settle(tab, due)
    }

    private func deliver(_ note: ChildSessionWakePolicy.Note, toParent parent: TaskTab, wakes: Bool) {
        var policy = policies[parent.id] ?? ChildSessionWakePolicy()
        let due = policy.noteArrived(note, wakes: wakes, activity(of: parent))
        policies[parent.id] = policy
        settle(parent, due)
    }

    private func recheckWake(of parent: TaskTab, excluding childID: UUID? = nil) {
        guard var policy = policies[parent.id] else { return }
        let due = policy.childrenChanged(activity(of: parent, excluding: childID))
        policies[parent.id] = policy
        settle(parent, due)
    }

    /// Delivers `due`, and while notes still wait on a working child,
    /// schedules the check for when that child reaches the limit.
    private func settle(_ parent: TaskTab, _ due: [ChildSessionWakePolicy.Note]?) {
        if let due { wake(parent, with: due) }
        limitChecks.removeValue(forKey: parent.id)?.cancel()
        let now = Date()
        guard policies[parent.id]?.hasWakingNotes == true,
              let deadline = workingChildren(of: parent).compactMap(\.workingSince)
                .filter({ ChildSessionWakePolicy.holdsWakes(workingSince: $0, now: now) }).min()?
                .addingTimeInterval(ChildSessionWakePolicy.workingLimit)
        else { return }
        let parentID = parent.id
        limitChecks[parentID] = Task { [weak self, weak parent] in
            try? await Task.sleep(for: .seconds(max(1, deadline.timeIntervalSinceNow)))
            guard !Task.isCancelled, let self, let parent, parent.isLive else { return }
            self.limitChecks[parentID] = nil
            self.recheckWake(of: parent)
        }
    }

    private func activity(of parent: TaskTab, excluding childID: UUID? = nil) -> ChildSessionWakePolicy.Activity {
        let now = Date()
        let working = workingChildren(of: parent).filter { session in
            session.tabID != childID && ChildSessionWakePolicy.holdsWakes(workingSince: session.workingSince, now: now)
        }
        return .init(parentIsWorking: isWorking(parent), childIsWorking: !working.isEmpty)
    }

    /// The running sessions of `parent`'s open children that are mid-turn.
    private func workingChildren(of parent: TaskTab) -> [HeadlessSession] {
        let parentID = parent.id
        return (parent.task?.liveTabs ?? []).compactMap { tab in
            guard tab.parentTabID == parentID,
                  let session = AgentSessionManager.shared.existingSession(for: tab.id) as? HeadlessSession,
                  !session.hasExited, session.isWorking
            else { return nil }
            return session
        }
    }

    /// A wake that cannot reach the parent leaves its notes held, for the
    /// user's next message to carry.
    private func wake(_ parent: TaskTab, with notes: [ChildSessionWakePolicy.Note]) {
        guard !notes.isEmpty else { return }
        let joined = Self.joined(notes)
        let display = ChildSessionFormats.summary(ofNotes: joined)
        let wire = joined + "\n\n" + ChildSessionFormats.wakeFooter
        if let task = parent.task, submitFromHost(wire, display: display, origin: .notes(notes), to: parent, in: task) {
            return
        }
        Log.agent.error("Could not deliver child-session notes to tab \(parent.id, privacy: .public)")
        hold(notes, for: parent)
    }

    private func hold(_ notes: [ChildSessionWakePolicy.Note], for parent: TaskTab) {
        var policy = policies[parent.id] ?? ChildSessionWakePolicy()
        policy.deliveryFailed(notes)
        policies[parent.id] = policy
    }

    /// Notes the user took off the parent's queue are held for its next
    /// turn, whoever starts it. A parent's message taken off a child's queue
    /// goes back to the parent as a held note saying so.
    private func hostMessagesReturned(_ messages: [HostMessage], by tab: TaskTab) {
        for message in messages {
            switch message.origin {
            case .notes(let notes):
                hold(notes, for: tab)
            case .fromParent(let text):
                guard let parent = parent(of: tab) else { continue }
                let note = ChildSessionFormats.messageRemovedNote(child: participant(tab), text: text)
                hold([.init(childID: tab.id, text: note, kind: .message)], for: parent)
            case nil:
                break
            }
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
    /// first. False when nothing could take it.
    @discardableResult
    private func submitFromHost(
        _ text: String, display: String, origin: HostMessageOrigin, to tab: TaskTab, in task: WorkTask
    ) -> Bool {
        let existing = AgentSessionManager.shared.existingSession(for: tab.id) as? HeadlessSession
        let session: HeadlessSession
        if let existing, !existing.hasExited {
            session = existing
        } else {
            guard tab.provider == .claudeCode, tab.transport == .headless,
                  let sessionID = tab.agentSessionID, !sessionID.isEmpty,
                  let resumed = AgentLauncher.relaunchHeadless(task: task, tab: tab) as? HeadlessSession,
                  !resumed.hasExited
            else { return false }
            session = resumed
        }
        session.submitFromHost(blocks: [.text(text)], display: [.text(display)], origin: origin)
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
    /// no session is running. The mode is the one the CLI confirmed, as the
    /// permission gate reads it, and a mode Plume does not recognize counts
    /// as manual.
    private struct LiveSettings {
        let permissionMode: PermissionMode
        let model: AgentModel?
        let effort: AgentEffort?

        init(of tab: TaskTab) {
            let session = AgentSessionManager.shared.existingSession(for: tab.id) as? HeadlessSession
            let running = session.flatMap { $0.hasExited ? nil : $0 }
            permissionMode = running.map { $0.confirmedPermissionMode.known ?? .manual } ?? Self.recordedMode(of: tab)
            model = running?.model ?? tab.model
            effort = running?.effort ?? tab.effort
        }

        /// The mode the tab would launch in.
        static func recordedMode(of tab: TaskTab) -> PermissionMode {
            HeadlessCommand.launchPermissionMode(
                AgentLauncher.resolvedPermissionMode(
                    tab: tab.permissionMode,
                    task: tab.task?.permissionMode,
                    appDefault: AppSettings.shared.resolvedDefaultPermissionMode
                )
            )
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
    func simulateTurnFinished(in child: TaskTab, text: String, wakes: Bool) {
        turnFinished(in: child, outcome: AgentTurnOutcome(
            text: text, isError: false, wasInterrupted: !wakes, isHostDriven: true
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
    /// shares the parent's folder, as a fork always does.
    @MainActor
    static func worktree(for request: StartSessionRequest, parent: TaskTab) async -> Result<Worktree?, ChildSessionError> {
        guard request.context == .fresh else { return .success(nil) }
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
