import Foundation
import os
import SwiftData

/// Runs child sessions: the sessions an agent in a headless tab starts
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
            proposalPermissionMode: { [weak tab] id in
                guard let tab else { return nil }
                let proposal = ChildSessionProposalStore(json: tab.childProposalsJSON).proposal(id: id)
                return proposal?.permissionMode.flatMap(PermissionMode.recognizing)
            },
            callTool: { [weak self, weak tab, weak session] call in
                let approvedByUser = call.tool == .startSession && session?.takeUserApproval(ofStart: call.toolUseID) == true
                guard let self, let tab, tab.isLive else {
                    return .failure("This session's tab is closed.")
                }
                return await self.handle(call, from: tab, forkCut: session?.latestForkCut, approvedByUser: approvedByUser)
            }
        )
        session.onTurnFinished = { [weak self, weak tab] outcome in
            guard let self, let tab, tab.isLive else { return }
            self.turnFinished(in: tab, outcome: outcome)
        }
        session.userMessagePreamble = { [weak self] in
            self?.takePreamble(forParent: tabID)
        }
        session.onHostMessagesReturned = { [weak self, weak tab] messages in
            guard let self, let tab, tab.isLive else { return }
            self.hostMessagesReturned(messages, by: tab)
        }
    }

    func attach(to session: CodexSession, tab: TaskTab) {
        let tabID = tab.id
        let role: PlumeMCPServer.Role = tab.isChildSession ? .child(parentID: tab.parentTabIDRaw) : .parent
        session.childSessionTools = CodexChildSessionTools(role: role) { [weak self, weak tab] call, approvedByUser in
            guard let self, let tab, tab.isLive else { return .failure("This session's tab is closed.") }
            return await self.handle(call, from: tab, forkCut: nil, approvedByUser: approvedByUser)
        }
        session.userMessagePreamble = { [weak self] in self?.takePreamble(forParent: tabID) }
        session.onTurnFinished = { [weak self, weak tab] outcome in
            guard let self, let tab, tab.isLive else { return }
            self.turnFinished(in: tab, outcome: outcome)
        }
        session.onHostMessagesReturned = { [weak self, weak tab] messages in
            guard let self, let tab, tab.isLive else { return }
            self.hostMessagesReturned(messages, by: tab)
            if messages.contains(where: \.isFromParent), let parent = self.parent(of: tab) {
                self.recheckWake(of: parent)
            }
        }
    }

    func tabForgotten(_ tabID: UUID) {
        policies.removeValue(forKey: tabID)
        childNames.removeValue(forKey: tabID)
        silentChildren.remove(tabID)
        limitChecks.removeValue(forKey: tabID)?.cancel()
        ChildSessionProposalActivity.shared.forget(tabID)
        ChildSessionProposalStoreCache.shared.forget(tabID)
        ChildSessionOfferBoard.shared.forget(tabID)
    }

    /// A parent's message still unread in a closing child goes back to the
    /// parent as a held note, and a closing child stops holding the parent's
    /// wakes. Call before the child's session is discarded.
    func childClosing(_ child: TaskTab) {
        guard let parent = parent(of: child) else { return }
        let session = AgentSessionManager.shared.existingSession(for: child.id)
        let unread = (session as? HeadlessSession)?.unreadHostMessages ?? (session as? CodexSession)?.unreadHostMessages ?? []
        for case .fromParent(let text)? in unread.map(\.origin) {
            let note = ChildSessionFormats.messageRemovedNote(child: participant(child), text: text, .closed)
            hold([.init(childID: child.id, text: note, kind: .message)], for: parent)
        }
        recheckWake(of: parent, excluding: child.id)
    }

    /// A restart stops the child's old process without finishing its turn,
    /// so nothing else tells the parent the child stopped working. Call once
    /// the resumed session has replaced it.
    func childRestarted(_ child: TaskTab) {
        guard let parent = parent(of: child) else { return }
        recheckWake(of: parent)
    }

    /// Selects the tab of the session a chat row names, opening its task,
    /// which may not be the row's. False when no open window holds it.
    @discardableResult
    func select(sessionID: String) -> Bool {
        guard let id = UUID(uuidString: sessionID),
              let task = CLICommandHandler.shared.currentTask(ofTab: id)?.task,
              let tab = task.liveTabs.first(where: { $0.id == id })
        else { return false }
        TaskStore.selectTab(tab, in: task)
        Notifier.shared.pendingRoute = Notifier.Route(taskID: task.id, tabID: tab.id)
        return true
    }

    nonisolated static func sessionID(of tab: TaskTab) -> String { tab.id.uuidString }

    /// Folders a launch adds for `tab`'s role: a parent with open children
    /// gets their notes folder. A running parent learns the folder from the
    /// `start_session` result instead of restarting.
    static func launchDirectories(for tab: TaskTab) -> [String] {
        guard !TaskStore.openChildren(of: tab).isEmpty else { return [] }
        return [AppPaths.sideSessionNotesDirectory(parentTabID: tab.id).path]
    }

    // MARK: - Tools

    private static func contextRefusal(_ context: StartSessionRequest.Context?, parent: TaskTab) -> ChildSessionError? {
        guard context == .fork, parent.provider == .codex else { return nil }
        return .invalid("A Codex parent can start only fresh sessions. Use context: fresh.")
    }

    /// `approvedByUser` is true when the user allowed this call from the
    /// permission prompt.
    private func handle(
        _ call: PlumeMCPServer.ToolCall, from tab: TaskTab, forkCut: String?, approvedByUser: Bool
    ) async -> PlumeMCPServer.ToolResult {
        let result: Result<String, ChildSessionError>
        switch call.tool {
        case .startSession:
            switch StartSessionCall.parse(call.arguments) {
            case .success(.start(let request)): result = await startSession(request, from: tab, approvedByUser: approvedByUser)
            case .success(.propose(let request)):
                result = propose(request, from: tab, forkCut: forkCut).map { proposal in
                    let proposed = ChildSessionFormats.proposed(title: proposal.title, taskID: proposal.id)
                    let dropped = request.permissionMode == .bypassPermissions
                        && proposal.permissionMode != PermissionMode.bypassPermissions.token
                    return dropped ? proposed + " " + ChildSessionFormats.bypassDroppedFromCard : proposed
                }
            case .success(.offer(let request)):
                if let toolUseID = call.toolUseID {
                    result = await offer(request, from: tab, toolUseID: toolUseID)
                } else {
                    result = .failure(.failed("The call carried no tool use id, so its offer card has nothing to attach to. Start or propose the session instead."))
                }
            case .success(.startProposal(let id, let wakeWhenDone, let settings)):
                result = await startProposal(
                    id, from: tab, wakeWhenDone: wakeWhenDone, settings: settings, byUser: false, approvedByUser: approvedByUser
                )
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
    func startSession(
        _ request: StartSessionRequest, from parent: TaskTab, approvedByUser: Bool
    ) async -> Result<String, ChildSessionError> {
        switch await launchChild(request, from: parent, approvedByUser: approvedByUser) {
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
        var notes = [started]
        if request.ignoresWorktreeRequest { notes.append(ChildSessionFormats.forkWorktreeIgnored) }
        if request.permissionMode == .bypassPermissions, child.permissionMode != .bypassPermissions,
           AppSettings.shared.showsBypassPermissions {
            notes.append(ChildSessionFormats.bypassNotApproved)
        }
        return notes.joined(separator: " ")
    }

    /// `proposalID` names the proposal this launch starts. It is recorded as
    /// started in the same step that opens the child's tab, so no later
    /// failure or crash can let it start twice. A fork cuts the parent's
    /// conversation at `forkCut`, or relaunches without it if the CLI
    /// refuses it. `approvedByUser` says the user approved this start, which
    /// bypass needs when the parent lacks it (`ChildSessionPermissions`).
    private func launchChild(
        _ request: StartSessionRequest,
        from parent: TaskTab,
        approvedByUser: Bool,
        proposalID: String? = nil,
        forkCut: String? = nil
    ) async -> Result<TaskTab, ChildSessionError> {
        guard !parent.isChildSession else { return .failure(.failed("This session cannot start sessions of its own.")) }
        guard parent.transport == .headless else {
            return .failure(.failed("Only a headless session can start a child session."))
        }
        if let refusal = Self.contextRefusal(request.context, parent: parent) { return .failure(refusal) }
        if request.provider == .codex, request.context == .fork {
            return .failure(.invalid(StartSessionRequest.codexForkError))
        }
        guard parent.task != nil, let context = parent.modelContext else {
            return .failure(.failed("This session's task is gone."))
        }
        let live = LiveSettings(of: parent)
        let mode: PermissionMode
        switch ChildSessionPermissions.mode(
            requested: request.permissionMode,
            parent: live.permissionMode,
            showsBypassPermissions: AppSettings.shared.showsBypassPermissions,
            approvedByUser: approvedByUser
        ) {
        case .success(let resolved): mode = resolved
        case .failure(let error): return .failure(error)
        }
        let parentSessionID = parent.agentSessionID ?? ""
        if request.context == .fork, parentSessionID.isEmpty {
            return .failure(.failed("This conversation has no session id yet, so it cannot be forked."))
        }

        let parentIsOpen = { parent.isLive && parent.task?.isArchived == false }
        guard parentIsOpen() else { return .failure(.parentClosed) }
        let worktree: ChildSessionWorkspace.Worktree?
        switch await ChildSessionWorkspace.worktree(for: request, parent: parent) {
        case .success(let made): worktree = made
        case .failure(let error): return .failure(error)
        }
        // Cutting the worktree took a while: the parent may have closed, or
        // moved to another task, where the child then opens.
        guard parentIsOpen(), let task = parent.task else {
            if let worktree { await ChildSessionWorkspace.remove(worktree) }
            return .failure(.parentClosed)
        }

        let name = request.name ?? WorkspaceProvisioner.slugify(request.title)
        let child = TaskStore.addChildTab(to: task, parent: parent, provider: request.provider, in: context)
        child.title = request.title
        child.titleSource = .custom
        TitleStore.shared.setTitle(request.title, forTab: child.id, source: .custom)
        childNames[child.id] = name
        if !request.wakeWhenDone { silentChildren.insert(child.id) }
        if let proposalID {
            let recorded = withProposals(of: parent, prunes: false) {
                $0.markStarted(id: proposalID, sessionID: Self.sessionID(of: child), name: name, now: .now)
            }
            if !recorded {
                Log.agent.error("Proposal \(proposalID, privacy: .public) vanished while it started")
            }
        }
        if request.provider == .claudeCode {
            if parent.provider == .claudeCode {
                TabLaunchChoices(parent).apply(to: child)
                if let model = live.model { child.model = model }
                if let effort = live.effort { child.effort = effort }
            }
            child.transport = .headless
            child.permissionMode = mode
        } else {
            child.codexCollaborationMode = .default
            child.permissionModeRaw = AgentPermissionPreset.codexWorkspace.id
        }
        if let model = request.model {
            child.model = model
            child.isModelUserChosen = true
        }
        if let effort = request.effort {
            child.effort = effort
            child.isEffortUserChosen = true
        }
        ChildSessionWorkspace.apply(worktree, to: child, parent: parent)

        let notes = AppPaths.sideSessionNotesDirectory(parentTabID: parent.id)
        try? FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        var directories = parent.additionalDirectories
        directories.append(notes.path)
        child.additionalDirectories = AdditionalDirectories.list(directories, excluding: nil)

        let isFork = request.context == .fork
        let newSessionID = UUID().uuidString.lowercased()
        // A fork launches where the parent's transcript is, whatever folder
        // the tab records, and the CLI writes the new transcript beside it.
        let launchDirectory = isFork
            ? AgentLauncher.claudeLaunchDirectory(for: parent, resumeSessionID: parentSessionID)
            : TabDirectoryStore.shared.directory(for: child)
        if request.provider == .claudeCode { child.agentSessionID = newSessionID }
        if request.provider == .claudeCode, let directory = launchDirectory {
            child.sessionJSONLPath = SessionJSONLReader.resolvedTranscriptPath(
                workingDirectory: directory, sessionID: newSessionID
            )
        }

        let brief = ChildSessionFormats.firstMessage(
            prompt: request.prompt, background: request.background,
            notesFolder: request.provider == .codex && launchDirectory == nil ? nil : notes.path
        )
        PendingFirstMessageStore.shared.set(OptimisticFirstMessage(text: brief), forTab: child.id)

        AgentLauncher.launch(
            blocks: [],
            task: task,
            tab: child,
            resumeSessionID: isFork ? parentSessionID : nil,
            fork: isFork ? HeadlessCommand.Fork(newSessionID: newSessionID, cutAfterMessageUUID: forkCut) : nil,
            sessionID: isFork ? nil : newSessionID,
            effort: child.isEffortUserChosen ? child.effort : nil
        )
        let session = AgentSessionManager.shared.existingSession(for: child.id)
        guard let session, !session.hasExited else {
            let reason = session.map(Self.launchFailure) ?? "no session was created"
            TaskStore.closeTab(child, in: context)
            if let proposalID { withProposals(of: parent, prunes: false) { $0.reopen(id: proposalID) } }
            if let worktree { await ChildSessionWorkspace.remove(worktree) }
            return .failure(.failed("The session could not start: \(reason)"))
        }
        if let worktree { ChildSessionWorkspace.recordOwnership(of: worktree, in: task) }
        let opening = HostMessage(
            display: [UserContentBlock.text(request.prompt)].normalized,
            wire: [UserContentBlock.text(brief)].normalized,
            origin: .fromParent(text: request.prompt)
        )
        if isFork, forkCut != nil, let session = session as? HeadlessSession {
            session.onCutRefused = { [weak self, weak child] in
                guard let self, let child, child.isLive, let task = child.task else { return false }
                let relaunched = AgentLauncher.relaunchForkWithoutCut(
                    task: task, tab: child, resumeSessionID: parentSessionID, newSessionID: newSessionID,
                    effort: child.isEffortUserChosen ? child.effort : nil,
                    resending: [QueuedMessage(parts: [.host(opening)])]
                ) as? HeadlessSession
                if relaunched == nil || relaunched?.hasExited == true {
                    let reason = relaunched.map(Self.launchFailure) ?? "no session was created"
                    self.turnFinished(in: child, outcome: AgentTurnOutcome(
                        text: reason,
                        isError: true, wasInterrupted: false, isHostDriven: true, isParentDriven: true,
                        exitedMidTurn: true
                    ))
                }
                return true
            }
        }
        Self.submit(opening, to: session)
        return .success(child)
    }

    // MARK: - Offers

    /// An id for an offer no CLI call raised, as the control server's.
    nonisolated static func mintOfferID() -> String { "offer_\(UUID().uuidString.lowercased())" }

    typealias ChildLauncher = (StartSessionRequest, TaskTab) async -> Result<TaskTab, ChildSessionError>

    /// Shows a card asking the user whether to start the session or have the
    /// agent do the work itself, and answers the call only once they choose.
    /// The card's click is the user's approval, so a start asks nothing more.
    /// A start that fails leaves the card pending with the reason. The task
    /// cancelling, which the CLI's `notifications/cancelled` and the
    /// session's exit cause, withdraws the offer.
    func offer(
        _ request: StartSessionRequest, from parent: TaskTab, toolUseID: String
    ) async -> Result<String, ChildSessionError> {
        let (request, dropped) = cardRequest(request, from: parent)
        if let refusal = raiseOffer(request, from: parent, toolUseID: toolUseID) { return .failure(refusal) }
        let answered = await awaitOffer(request, from: parent, toolUseID: toolUseID)
        return dropped ? answered.map { $0 + " " + ChildSessionFormats.bypassDroppedFromCard } : answered
    }

    /// A card shows no permission mode, so a click on it must never start a
    /// bypass session the user could not see. Only a parent already in
    /// bypass may record one; any other gets auto in its place.
    func cardRequest(
        _ request: StartSessionRequest, from parent: TaskTab
    ) -> (request: StartSessionRequest, droppedBypass: Bool) {
        guard request.permissionMode == .bypassPermissions,
              LiveSettings(of: parent).permissionMode != .bypassPermissions
        else { return (request, false) }
        var lowered = request
        lowered.permissionMode = .auto
        return (lowered, true)
    }

    /// Puts the card up, or says why it can't go up.
    func raiseOffer(_ request: StartSessionRequest, from parent: TaskTab, toolUseID: String) -> ChildSessionError? {
        guard !parent.isChildSession else { return .failed("This session cannot start sessions of its own.") }
        guard LiveSettings(of: parent).permissionMode != .plan else { return .parentInPlanMode }
        if let refusal = Self.contextRefusal(request.context, parent: parent) { return refusal }
        if let existing = ChildSessionOfferBoard.shared.offer(toolUseID), existing.result == nil {
            return .failed("An offer for this call is already waiting.")
        }
        ChildSessionOfferBoard.shared.raise(toolUseID, parentTabID: parent.id, request: request)
        return nil
    }

    /// Answers a raised offer once the user has chosen.
    ///
    /// A withdrawal that arrives while the child is launching lets the
    /// launch finish: the card reads started, and the parent, whose call no
    /// longer waits for the result, gets a note saying so. The note rides the
    /// parent's next turn rather than waking it, since the withdrawal usually
    /// means the user just stopped that turn. `launch` stands in for opening
    /// the child's tab in tests.
    func awaitOffer(
        _ request: StartSessionRequest, from parent: TaskTab, toolUseID: String, launch: ChildLauncher? = nil
    ) async -> Result<String, ChildSessionError> {
        let board = ChildSessionOfferBoard.shared
        let withdrawn = { Task.isCancelled || board.isWithdrawn(toolUseID) }
        let withdraw = { () -> Result<String, ChildSessionError> in
            board.settle(toolUseID, .withdrawn, result: ChildSessionFormats.offerWithdrawn)
            return .failure(.failed(ChildSessionFormats.offerWithdrawn))
        }
        while true {
            let action = await withTaskCancellationHandler {
                await board.nextAction(toolUseID)
            } onCancel: {
                Task { @MainActor in board.answer(toolUseID, .withdraw) }
            }
            switch action {
            case .doItHere:
                if withdrawn() { return withdraw() }
                let text = ChildSessionFormats.offerDeclined(title: request.title)
                board.settle(toolUseID, .declined, result: text)
                return .success(text)
            case .withdraw:
                return withdraw()
            case .newSession:
                if withdrawn() { return withdraw() }
                guard parent.isLive else {
                    board.settle(toolUseID, .withdrawn, result: ChildSessionFormats.offerWithdrawn)
                    return .failure(.parentClosed)
                }
                board.setStarting(toolUseID)
                let launched = if let launch {
                    await launch(request, parent)
                } else {
                    await launchChild(request, from: parent, approvedByUser: true)
                }
                switch launched {
                case .success(let child):
                    let text = startedText(for: child, request: request, parent: parent)
                    let name = childNames[child.id] ?? WorkspaceProvisioner.slugify(request.title)
                    if withdrawn() {
                        let note = ChildSessionFormats.offerStartedNote(title: request.title, child: participant(child))
                        deliver(.init(childID: child.id, text: note, kind: .message), toParent: parent, wakes: false)
                    }
                    board.settle(toolUseID, .started(sessionID: Self.sessionID(of: child), name: name), result: text)
                    return .success(text)
                case .failure(let error):
                    if withdrawn() { return withdraw() }
                    board.fail(toolUseID, error.message)
                }
            }
        }
    }

    // MARK: - Proposals

    /// Records a card for the user to start, and starts nothing.
    /// `forkCut` is where a fork proposal's conversation stands now.
    func propose(
        _ request: StartSessionRequest, from parent: TaskTab, forkCut: String? = nil, now: Date = .now
    ) -> Result<ChildSessionProposal, ChildSessionError> {
        guard !parent.isChildSession else { return .failure(.failed("This session cannot start sessions of its own.")) }
        if let refusal = Self.contextRefusal(request.context, parent: parent) { return .failure(refusal) }
        guard ChildSessionProposalStore(json: parent.childProposalsJSON).isWritable else {
            return .failure(.failed("This session's stored proposals could not be read, so no new one can be recorded."))
        }
        let request = cardRequest(request, from: parent).request
        return .success(withProposals(of: parent, now: now) { store in
            var id = ChildSessionProposalStore.makeID()
            while store.proposal(id: id) != nil { id = ChildSessionProposalStore.makeID() }
            let proposal = ChildSessionProposal(id: id, request: request, createdAt: now, forkCut: forkCut)
            store.add(proposal)
            return proposal
        })
    }

    /// Starts a pending proposal with the brief and settings it was proposed
    /// with, refusing repeated `settings` that differ from them. A start the
    /// user made from the card also tells the parent, as a note that wakes it
    /// unless the proposal asked not to be woken, and a refusal shows on the
    /// card. `byUser` is a start from the card, whose click approves it;
    /// `approvedByUser` is a start by `proposal_id` the user allowed from the
    /// permission prompt.
    func startProposal(
        _ id: String,
        from parent: TaskTab,
        wakeWhenDone: Bool? = nil,
        settings: [String: JSONValue] = [:],
        byUser: Bool,
        approvedByUser: Bool = false,
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

        if request.context == .fork, proposal.forkCut == nil {
            Log.agent.info("Proposal \(id, privacy: .public) recorded no fork point; forking the conversation as it is now")
        }
        activity.begin(id, in: parent.id)
        let child: TaskTab
        switch await launchChild(
            request, from: parent, approvedByUser: byUser || approvedByUser, proposalID: id, forkCut: proposal.forkCut
        ) {
        case .success(let launched):
            activity.end(id, in: parent.id, failure: nil)
            child = launched
        case .failure(let error):
            // A closed parent's activity is already forgotten, and has no card to show it.
            let showsOnCard = byUser && parent.isLive && error != .parentClosed
            activity.end(id, in: parent.id, failure: showsOnCard ? Self.cardFailure(error) : nil)
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

    /// Runs `body` on the tab's proposals, then prunes them and saves the
    /// context itself. Otherwise only a status change saves it, and a
    /// dismissal changes none, so it would not survive a relaunch.
    @discardableResult
    func withProposals<T>(
        of tab: TaskTab, now: Date = .now, prunes: Bool = true, _ body: (inout ChildSessionProposalStore) -> T
    ) -> T {
        var store = ChildSessionProposalStore(json: tab.childProposalsJSON)
        let result = body(&store)
        if prunes { store.prune(now: now) }
        let json = store.json
        if tab.childProposalsJSON != json {
            tab.childProposalsJSON = json
            do {
                try tab.modelContext?.save()
            } catch {
                Log.agent.error("Could not save child session proposals: \(error.localizedDescription, privacy: .public)")
            }
        }
        return result
    }

    /// The tab's proposals as they read at `now`, without saving anything.
    func proposals(of tab: TaskTab, now: Date = .now) -> ChildSessionProposalStore {
        var store = ChildSessionProposalStore(json: tab.childProposalsJSON)
        store.prune(now: now)
        return store
    }

    private static func launchFailure(of session: any AgentSession) -> String {
        if let failure = session.startFailure {
            return [failure.title, failure.detail].compactMap { $0 }.joined(separator: ": ")
        }
        return session.lastError ?? "The agent exited at launch."
    }

    private func sendMessage(_ arguments: [String: JSONValue], from sender: TaskTab) -> Result<String, ChildSessionError> {
        guard let to = arguments["to"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !to.isEmpty else {
            return .failure(.invalid("to is required"))
        }
        guard let message = arguments["message"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !message.isEmpty
        else { return .failure(.invalid("message is required")) }
        guard sender.task != nil else { return .failure(.failed("This session's task is gone.")) }

        if sender.isChildSession {
            guard to == "parent" || to.caseInsensitiveCompare(sender.parentTabIDRaw) == .orderedSame else {
                return .failure(.notRelated(to))
            }
            guard let parent = parent(of: sender) else {
                return .failure(.failed("The session that started this one is closed, so nothing can reach it."))
            }
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
        guard let id = UUID(uuidString: to), let target = TaskStore.openTab(id, in: sender.modelContext) else {
            return .failure(.unknownSession(to))
        }
        guard target.parentTabID == sender.id else { return .failure(.notRelated(to)) }
        let note = ChildSessionFormats.messageFromParentNote(parent: participant(sender), text: message)
        let queued = isWorking(target)
        guard let targetTask = target.task,
              submitFromHost(note, display: message, origin: .fromParent(text: message), to: target, in: targetTask)
        else {
            return .failure(.failed("Session \(to) could not be reached."))
        }
        return .success(ChildSessionFormats.delivered(to: TitleStore.shared.chipTitle(for: target), queued ? .queued : .sent))
    }

    // MARK: - Notes

    private func turnFinished(in tab: TaskTab, outcome: AgentTurnOutcome) {
        // A turn cannot end while a call waits, so the CLI has dropped any
        // offer still pending in it.
        ChildSessionOfferBoard.shared.withdrawAll(inTab: tab.id)
        if let parent = parent(of: tab) {
            // Only a turn the parent started reports back, not one the user
            // or the child's own children drove. Either way this child has
            // stopped working, which may free notes from its siblings.
            if outcome.isParentDriven {
                let note = ChildSessionFormats.turnFinishedNote(
                    child: participant(tab), text: ChildSessionFormats.reportText(of: outcome)
                )
                let wakes = !outcome.wasInterrupted && !silentChildren.contains(tab.id)
                deliver(.init(childID: tab.id, text: note), toParent: parent, wakes: wakes)
            } else {
                recheckWake(of: parent)
            }
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
              let deadline = workingChildren(of: parent).compactMap({ $0.workingSince })
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
    private func workingChildren(of parent: TaskTab) -> [(tabID: UUID, workingSince: Date?)] {
        TaskStore.openChildren(of: parent).compactMap { tab in
            guard let session = AgentSessionManager.shared.existingSession(for: tab.id), !session.hasExited else { return nil }
            if let headless = session as? HeadlessSession, headless.isWorking {
                return (tab.id, headless.workingSince)
            }
            if let codex = session as? CodexSession, codex.isWorking || codex.hasPendingParentBrief {
                return (tab.id, codex.workingSince)
            }
            return nil
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
    /// turn, whoever starts it. Notes that rode a message the user withdrew
    /// go back as they were, so a waking one still wakes the parent. A
    /// parent's message taken off a child's queue goes back to the parent as
    /// a held note saying so.
    private func hostMessagesReturned(_ messages: [HostMessage], by tab: TaskTab) {
        for message in messages {
            switch message.origin {
            case .notes(let notes):
                hold(notes, for: tab)
            case .preamble(let taken):
                var policy = policies[tab.id] ?? ChildSessionWakePolicy()
                let due = policy.userMessageWithdrawn(taken, activity(of: tab))
                policies[tab.id] = policy
                settle(tab, due)
            case .fromParent(let text):
                guard let parent = parent(of: tab) else { continue }
                let note = ChildSessionFormats.messageRemovedNote(child: participant(tab), text: text)
                hold([.init(childID: tab.id, text: note, kind: .message)], for: parent)
            case nil:
                break
            }
        }
    }

    private func takePreamble(forParent tabID: UUID) -> HostMessage? {
        guard var policy = policies[tabID] else { return nil }
        let taken = policy.userWillSend()
        policies[tabID] = policy
        guard !taken.all.isEmpty else { return nil }
        let text = Self.joined(taken.all)
        return HostMessage(display: [.text(text)], wire: [.text(text)], origin: .preamble(taken))
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
        guard tab.transport == .headless else { return false }
        let existing = AgentSessionManager.shared.existingSession(for: tab.id)
        let session: any AgentSession
        if let existing, !existing.hasExited {
            session = existing
        } else {
            guard let sessionID = tab.agentSessionID, !sessionID.isEmpty,
                  let resumed = AgentLauncher.relaunchHeadless(task: task, tab: tab),
                  !resumed.hasExited
            else { return false }
            session = resumed
        }
        Self.submit(HostMessage(display: [.text(display)], wire: [.text(text)], origin: origin), to: session)
        return true
    }

    private static func submit(_ message: HostMessage, to session: any AgentSession) {
        if let session = session as? HeadlessSession {
            session.submitFromHost(blocks: message.wire, display: message.display, origin: message.origin)
        } else if let session = session as? CodexSession {
            session.submit(QueuedMessage(parts: [.host(message)]))
        }
    }

    private func isWorking(_ tab: TaskTab) -> Bool {
        let session = AgentSessionManager.shared.existingSession(for: tab.id)
        return session?.isWorking == true || (session as? CodexSession)?.hasPendingParentBrief == true
    }

    /// The open tab that started `tab`, in any task.
    func parent(of tab: TaskTab) -> TaskTab? {
        TaskStore.openParent(of: tab)
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
            if tab.provider == .codex {
                let session = AgentSessionManager.shared.existingSession(for: tab.id) as? CodexSession
                let collaboration = session.flatMap { $0.hasExited ? nil : $0.childSessionCollaborationMode }
                    ?? tab.codexCollaborationMode
                permissionMode = collaboration == .plan ? .plan : .manual
                model = nil
                effort = nil
                return
            }
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
            text: text, isError: false, wasInterrupted: !wakes, isHostDriven: true, isParentDriven: true
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
