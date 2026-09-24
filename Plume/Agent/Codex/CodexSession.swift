import Foundation
import os

/// One Codex conversation, driving a tab.
///
/// The counterpart to `HeadlessSession`: same job, different protocol. Holds
/// the app-server client, the live turn state the chat renders, and the
/// approvals waiting on the user. See `docs/codex-protocol.md`.
@MainActor
@Observable
final class CodexSession: AgentSession {
    /// Permission profiles and the rest of the v2 thread surface are gated
    /// behind this negotiated capability in current Codex releases.
    static let initializeCapabilities: JSONValue = .object([
        "experimentalApi": .bool(true),
        "optOutNotificationMethods": .array(
            CodexCommand.ignoredNotifications.map(JSONValue.string)
        )
    ])

    let tabID: UUID
    var taskID: UUID
    var processIdentifier: Int32? { client.processIdentifier }
    private var hasUserSubmitted = false
    @ObservationIgnored var titleContextProvider: ((UUID) -> (transport: AgentTransport, userTaskName: String?)?)?
    @ObservationIgnored private var generateTitle: CodexTitleGenerator.Generate
    @ObservationIgnored private var titleTask: Task<Void, Never>?
    private var titleRequester = SessionTitleRequester()
    private var openingMessage: String?
    private var hasServerTitle = false
    private var serverTitle: String?
    private var titleRevision = 0

    private(set) var sessionID: String?
    private(set) var isWorking = false
    private(set) var hasExited = false
    private(set) var exitStatus: Int32?
    private(set) var pendingPermissions: [PendingPermission] = []
    private(set) var streamingText = ""
    private(set) var streamingThinking = ""
    private(set) var rateLimit: RateLimitInfo?
    private var accountRateLimits = CodexRateLimits()
    var quotaWindows: [CodexQuotaWindow] { CodexQuotaStore.shared.windows }
    private var queuePaused = false
    private var selectedPermissionProfile: String?
    /// Codex reports tokens, never dollars.
    let sessionCostUSD: Double? = nil
    private(set) var contextWindow: Int?
    private(set) var contextUsedTokens: Int?
    var nominalContextWindow: Int? { nil }
    /// Codex has no slash-command catalog. The composer separately discovers
    /// skills and completes their native `$name` references.
    let slashCommands: [SlashCommand] = []
    var startFailure: ChatStartFailure? {
        guard hasExited else { return nil }
        // An unsolicited app-server exit is a disconnect even at status zero.
        return ChatStartFailure.classify(error: lastError, exitStatus: exitStatus == 0 ? nil : exitStatus, provider: .codex)
    }

    private(set) var lastError: String?
    private(set) var permissionMode: PermissionMode?
    private(set) var model: AgentModel?
    private(set) var effort: AgentEffort?
    private(set) var collaborationMode: CodexCollaborationMode = .default
    private(set) var hasReportedModeAndModel = false
    private(set) var queuedMessages: [[UserContentBlock]] = []

    let supportsPlanApproval = true
    let supportsSteering = true
    private(set) var isSteering = false
    var canSteer: Bool {
        isWorking && currentTurnID != nil && sessionID != nil && !isSteering && !hasExited
    }
    private(set) var planProposal: CodexItemStore.PlanProposal?

    private let client: CodexAppServerClient
    private let standaloneRemoteControl: CodexRemoteControl?
    var remoteControl: CodexRemoteControl { client.sharedRemoteControl ?? standaloneRemoteControl! }
    /// Headless Codex tabs share a host and its remote-control state.
    var effectiveRemoteControl: CodexRemoteControl {
        CodexRemoteControlLease.shared.owner ?? remoteControl
    }
    var isRemotelyControlled: Bool { !hasExited && remoteControl.isAvailableForRemoteAccess }
    /// A thread id is published as soon as start/resume answers so the model
    /// can persist it, but user turns wait until authoritative history has
    /// finished merging.
    private var isReady = false
    private var hasStartedHandshake = false
    private var nextTurnStartSequence = 0
    private var pendingTurnStartSequence: Int?
    /// `turn/interrupt` is addressed to a specific turn, so the id from
    /// `turn/started` has to be kept.
    private var currentTurnID: String?
    /// The composer reports work as soon as `turn/start` is written, before
    /// either source of the turn id may have arrived. Remember an interrupt
    /// requested in that window and deliver it once the id is known.
    private var interruptRequested = false
    /// Approval requests are answered by the ID that carried them.
    private var permissionRequestIDs: [String: CodexRPC.RequestID] = [:]
    private var permissionKinds: [String: PermissionRequestKind] = [:]
    private var deferredInbound: [DeferredInbound] = []
    private var knownChildThreadIDs: Set<String> = []
    private var unrelatedThreadIDs: Set<String> = []
    private var foreignInbound: [String: [DeferredInbound]] = [:]
    private var ancestryReads: [String: Task<Void, Never>] = [:]

    private enum DeferredInbound {
        case notification(String, JSONValue)
        case request(CodexRPC.RequestID, String, JSONValue)
    }

    private enum PermissionRequestKind {
        case decision
        case permissions(JSONValue)
        case question
    }

    private struct ChildFileChangeKey: Hashable {
        let threadID: String
        let turnID: String
        let itemID: String
    }

    /// Child transcripts stay out of the root chat. File changes are retained
    /// only because a later child approval request needs to show its patch.
    private var childFileChanges: [ChildFileChangeKey: JSONValue] = [:]
    private var childHydrations: [String: Task<Void, Never>] = [:]
    private var attemptedChildHydrations: Set<String> = []
    private var failedChildHydrations: Set<String> = []

    init(tabID: UUID, taskID: UUID, initialEffort: AgentEffort? = nil, client: CodexAppServerClient? = nil, generateTitle: CodexTitleGenerator.Generate? = nil) {
        let client = client ?? CodexAppServerClient.sharedSessionClient()
        self.tabID = tabID
        self.taskID = taskID
        self.effort = initialEffort
        self.client = client
        self.generateTitle = generateTitle ?? CodexTitleGenerator.generate
        self.standaloneRemoteControl = client.usesSharedServer ? nil : CodexRemoteControl(lease: .shared) { [client] method, params in
            try await client.send(method, params)
        }
        client.onNotification = { [weak self] method, params in
            self?.handle(notification: method, params: params)
        }
        client.onServerRequest = { [weak self] id, method, params in
            self?.handle(request: id, method: method, params: params)
        }
        client.onExit = { [weak self] status, message in
            self?.handleExit(status: status, message: message)
        }
    }

    func start(
        workingDirectory: String?,
        resumeThreadID: String?,
        model: AgentModel?,
        collaborationMode: CodexCollaborationMode = .default,
        permissionProfile: String? = nil,
        defaultPermissionProfile: String = AgentPermissionPreset.codexWorkspace.id,
        preserveRemoteConfiguration: Bool = false,
        environment: [String: String]
    ) {
        guard !hasStartedHandshake else { return }
        if preserveRemoteConfiguration { effort = nil }
        if let model, !preserveRemoteConfiguration { self.model = model }
        self.collaborationMode = collaborationMode
        hasStartedHandshake = true
        isReady = false
        do {
            try client.start(workingDirectory: workingDirectory, environment: environment)
        } catch {
            Log.agent.error("Codex launch failed: \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
            hasExited = true
            StatusEngine.shared.setStatus(.error, taskID: taskID, tabID: tabID, notifiable: hasUserSubmitted)
            return
        }
        Task {
            await handshake(
                workingDirectory: workingDirectory,
                resumeThreadID: resumeThreadID,
                permissionProfile: permissionProfile,
                defaultPermissionProfile: defaultPermissionProfile,
                preserveRemoteConfiguration: preserveRemoteConfiguration
            )
        }
    }

    private func handshake(
        workingDirectory: String?,
        resumeThreadID: String?,
        permissionProfile: String?,
        defaultPermissionProfile: String,
        preserveRemoteConfiguration: Bool
    ) async {
        do {
            _ = try await client.send("initialize", .object([
                "clientInfo": .object([
                    "name": .string("Plume"),
                    "title": .string(AppIdentity.displayName),
                    "version": .string(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0")
                ]),
                "capabilities": Self.initializeCapabilities
            ]))
            client.notify("initialized")

            await hydrateRateLimits()

            await hydrateCatalogs(workingDirectory: workingDirectory)

            let resolvedPermissionProfile = CodexCatalogStore.shared.resolvedProfile(
                for: tabID,
                requestedID: permissionProfile,
                fallbackID: defaultPermissionProfile
            )

            var params: [String: JSONValue] = [:]
            if let workingDirectory { params["cwd"] = .string(workingDirectory) }
            if let model { params["model"] = .string(model.id) }
            selectedPermissionProfile = resolvedPermissionProfile?.id
            if let resolvedPermissionProfile { params["permissions"] = .string(resolvedPermissionProfile.id) }
            let method: String
            if let resumeThreadID, !resumeThreadID.isEmpty {
                method = "thread/resume"
                if preserveRemoteConfiguration {
                    // Attach to the shared server's running thread without
                    // applying stale tab defaults over the remote client.
                    params = [:]
                    selectedPermissionProfile = nil
                }
                params["threadId"] = .string(resumeThreadID)
            } else {
                method = "thread/start"
            }
            let result = try await client.send(method, .object(params))
            guard adopt(startResponse: result), let threadID = sessionID else {
                throw SessionFailure.missingThreadID
            }
            drainDeferredInbound()
            await hydrateHistory(threadID: threadID)
            planProposal = CodexItemStore.shared.latestPendingPlan(forTab: tabID)
            guard !hasExited else { return }
            isReady = true
            backgroundTasks.refresh(threadID: threadID)
            Task { await refreshSkills() }
            if !isWorking { StatusEngine.shared.setStatus(.awaitingReply, taskID: taskID, tabID: tabID) }
            flushQueue()
        } catch {
            reportFailure(error)
            stop()
        }
    }

    func hydrateRateLimits() async {
        do {
            let result = try await client.send("account/rateLimits/read", .object([:]))
            rateLimit = accountRateLimits.receive(result)
            CodexQuotaStore.shared.record(result)
        } catch {
            // API-key accounts may have no account quota snapshot.
            Log.agent.error("Codex account quota load failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func hydrateCatalogs(workingDirectory: String?) async {
        do {
            let values = try await paginated(
                method: "model/list",
                baseParams: ["includeHidden": .bool(false)]
            )
            CodexCatalogStore.shared.replaceModels(tabID: tabID, values: values)
        } catch {
            Log.agent.error("Codex model catalog load failed: \(error.localizedDescription, privacy: .public)")
        }
        do {
            var params: [String: JSONValue] = [:]
            if let workingDirectory { params["cwd"] = .string(workingDirectory) }
            let values = try await paginated(method: "permissionProfile/list", baseParams: params)
            CodexCatalogStore.shared.replaceProfiles(tabID: tabID, values: values)
        } catch {
            Log.agent.error("Codex permission profile load failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func paginated(
        method: String,
        baseParams: [String: JSONValue]
    ) async throws -> [JSONValue] {
        var cursor: String?
        var values: [JSONValue] = []
        repeat {
            var params = baseParams
            if let cursor { params["cursor"] = .string(cursor) }
            let result = try await client.send(method, .object(params))
            values += result["data"]?.arrayValue ?? []
            cursor = result["nextCursor"]?.stringValue
        } while cursor != nil
        return values
    }

    /// Start and resume report model and effort beside `thread`, not inside
    /// it. The nested fields are persisted summaries and can be stale.
    @discardableResult
    private func adopt(startResponse result: JSONValue) -> Bool {
        guard let id = result["thread"]?["id"]?.stringValue, !id.isEmpty else { return false }
        sessionID = id
        restoreRuntimeState(from: result["thread"] ?? .null)
        serverTitle = CodexThreadTitle.name(result["thread"]?["name"]?.stringValue)
        hasServerTitle = serverTitle != nil
        if let title = CodexThreadTitle.title(thread: result["thread"] ?? .null) {
            TitleStore.shared.setTitle(title, forTab: tabID)
        }
        TabDirectoryStore.shared.setDirectory(result["thread"]?["cwd"]?.stringValue, forTab: tabID)
        if let reported = result["model"]?.stringValue {
            model = CodexCatalogStore.shared.models(for: tabID).first { $0.id == reported }
                ?? AgentModel(id: reported, label: reported)
        }
        if effort == nil, let reported = result["reasoningEffort"]?.stringValue {
            effort = AgentEffort(rawValue: reported)
        }
        if let effort, !CodexCatalogStore.shared.efforts(for: tabID, modelID: model?.id).contains(effort) {
            self.effort = result["reasoningEffort"]?.stringValue.flatMap(AgentEffort.recognizing)
        }
        hasReportedModeAndModel = true
        return true
    }

    /// Resume can attach after a remote turn started, so no turn/started
    /// event is guaranteed. Apply this snapshot before draining buffered
    /// notifications; newer completion/start events then always win. History
    /// hydration must never reapply this older runtime snapshot.
    private func restoreRuntimeState(from thread: JSONValue) {
        let status = thread["status"]?["type"]?.stringValue
        let activeTurn = thread["turns"]?.arrayValue?.last {
            $0["status"]?.stringValue == "inProgress"
        }
        guard status == "active" || (status == nil && activeTurn != nil) else { return }
        isWorking = true
        currentTurnID = activeTurn?["id"]?.stringValue
        let flags = thread["status"]?["activeFlags"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let taskStatus: TaskStatus = flags.contains("waitingOnApproval") ? .permissionNeeded
            : flags.contains("waitingOnUserInput") ? .questionAsked : .working
        StatusEngine.shared.setStatus(taskStatus, taskID: taskID, tabID: tabID)
    }

    private func hydrateHistory(threadID: String) async {
        let revision = CodexItemStore.shared.revision(forTab: tabID)
        var cursor: String?
        var items: [JSONValue] = []
        repeat {
            var params: [String: JSONValue] = [
                "threadId": .string(threadID),
                "sortDirection": .string("asc")
            ]
            if let cursor { params["cursor"] = .string(cursor) }
            do {
                let result = try await client.send("thread/items/list", .object(params))
                items += result["data"]?.arrayValue ?? []
                cursor = result["nextCursor"]?.stringValue
            } catch {
                // History is an enhancement to a live conversation. A point
                // release without this method must not prevent sending.
                Log.agent.error("Codex history load failed: \(error.localizedDescription, privacy: .public)")
                return
            }
        } while cursor != nil
        CodexItemStore.shared.mergeHistory(tabID: tabID, entries: items, since: revision)
        CodexItemStore.shared.historyHydrated(tabID: tabID)
        for entry in items { discoverSubagents(in: entry["item"] ?? entry, historical: true) }
        CodexSubagentStore.shared.parentHistoryHydrated(tabID: tabID)
    }

    private func discoverSubagents(in item: JSONValue, historical: Bool = false) {
        let discovered = CodexSubagentStore.shared.receiveParentItem(tabID: tabID, taskID: taskID, item: item, historical: historical)
        for threadID in discovered {
            acceptChild(threadID)
            hydrateChild(threadID: threadID)
        }
    }

    private func hydrateChild(threadID: String, retry: Bool = false) {
        guard childHydrations[threadID] == nil,
              !attemptedChildHydrations.contains(threadID) || (retry && failedChildHydrations.contains(threadID))
        else { return }
        backgroundTasks.refresh(threadID: threadID)
        attemptedChildHydrations.insert(threadID)
        childHydrations[threadID] = Task { [weak self] in
            guard let self else { return }
            defer { childHydrations.removeValue(forKey: threadID) }
            do {
                let lifecycleRevision = CodexSubagentStore.shared.lifecycleRevision(tabID: tabID, threadID: threadID)
                let itemRevision = CodexSubagentStore.shared.revision(tabID: tabID, threadID: threadID)
                let metadata = try await client.send("thread/read", .object([
                    "threadId": .string(threadID), "includeTurns": .bool(false)
                ]))
                try Task.checkCancellation()
                CodexSubagentStore.shared.receiveThreadMetadata(tabID: tabID, threadID: threadID, thread: metadata["thread"] ?? .null, since: lifecycleRevision)
                var cursor: String?
                var entries: [JSONValue] = []
                repeat {
                    var params: [String: JSONValue] = ["threadId": .string(threadID), "sortDirection": .string("asc")]
                    if let cursor { params["cursor"] = .string(cursor) }
                    let result = try await client.send("thread/items/list", .object(params))
                    try Task.checkCancellation()
                    entries += result["data"]?.arrayValue ?? []
                    cursor = result["nextCursor"]?.stringValue
                } while cursor != nil
                CodexSubagentStore.shared.mergeHistory(tabID: tabID, threadID: threadID, entries: entries, since: itemRevision)
                failedChildHydrations.remove(threadID)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                failedChildHydrations.insert(threadID)
                CodexSubagentStore.shared.hydrationFailed(tabID: tabID, threadID: threadID, error: error)
            }
        }
    }

    private var skillDirectory: String? {
        TabDirectoryStore.shared.directory(forTab: tabID)
    }

    private func refreshSkills() async {
        guard let directory = skillDirectory else { return }
        do {
            let result = try await client.send("skills/list", .object([
                "cwds": .array([.string(directory)]), "forceReload": .bool(true)
            ]))
            guard !hasExited else { return }
            CodexSkillStore.shared.replace(result, directory: directory)
        } catch { /* Skill discovery never prevents ordinary conversation. */ }
    }

    private func turnInput(_ blocks: [UserContentBlock]) -> [JSONValue] {
        blocks.flatMap { block -> [JSONValue] in
            switch block {
            case .text(let text):
                CodexSkill.input(text: text, skills: CodexSkillStore.shared.skills(in: skillDirectory))
            case .image(let image):
                [.object(["type": .string("image"),
                          "url": .string("data:\(image.mediaType);base64,\(image.base64)")])]
            }
        }
    }

    @ObservationIgnored private lazy var backgroundTasks = CodexBackgroundTaskTracker(tabID: tabID) { [client] method, params in
        try await client.send(method, params)
    }

    // MARK: - Sending

    func submit(text: String) {
        submit(blocks: [.text(text)])
    }

    @discardableResult
    func submit(blocks: [UserContentBlock]) -> AgentDelivery {
        let normalized = blocks.normalized
        guard normalized.hasContent else { return .queued }
        hasUserSubmitted = true
        if openingMessage == nil, !normalized.plainText.isEmpty { openingMessage = normalized.plainText }
        // A normal follow-up is also an answer to a pending proposal. Clear
        // the decision surface immediately; `send` repeats this for a message
        // queued before the proposal arrived.
        planProposal = nil
        guard isReady, let threadID = sessionID, !isWorking else {
            queuedMessages.append(normalized)
            return .queued
        }
        queuePaused = false
        send(blocks: normalized, threadID: threadID)
        return .sent
    }

    /// Adds text to the active turn. Failure is reported to the caller so
    /// the composer retains the draft; steering never falls back to queueing.
    func steer(text: String) async -> Bool {
        await steer(blocks: [.text(text)])
    }

    func steer(blocks: [UserContentBlock]) async -> Bool {
        let normalized = blocks.normalized
        guard normalized.hasContent, canSteer,
              let threadID = sessionID, let turnID = currentTurnID
        else { return false }
        hasUserSubmitted = true
        isSteering = true
        defer { isSteering = false }
        do {
            _ = try await client.send("turn/steer", .object([
                "threadId": .string(threadID),
                "expectedTurnId": .string(turnID),
                "input": .array(turnInput(normalized))
            ]))
            planProposal = nil
            return true
        } catch {
            lastError = (error as? CodexAppServerClient.Failure).map(String.init(describing:))
                ?? error.localizedDescription
            return false
        }
    }

    private func send(blocks: [UserContentBlock], threadID: String) {
        planProposal = nil
        lastError = nil
        streamingText = ""
        streamingThinking = ""
        isWorking = true
        nextTurnStartSequence += 1
        let sequence = nextTurnStartSequence
        pendingTurnStartSequence = sequence
        StatusEngine.shared.setStatus(.working, taskID: taskID, tabID: tabID)
        var params: [String: JSONValue] = [
            "threadId": .string(threadID),
            "input": .array(turnInput(blocks))
        ]
        if let selectedPermissionProfile { params["permissions"] = .string(selectedPermissionProfile) }
        if let effort { params["effort"] = .string(effort.rawValue) }
        if let model { params["model"] = .string(model.id) }
        if let collaborationMode = collaborationModeValue() {
            params["collaborationMode"] = collaborationMode
        }
        Task {
            do {
                let result = try await client.send("turn/start", .object(params))
                if TitleStore.shared.title(forTab: tabID) == nil, let title = CodexThreadTitle.preview(blocks.plainText) {
                    TitleStore.shared.setTitle(title, forTab: tabID)
                }
                finishTurnStart(sequence: sequence, result: result)
            } catch {
                failTurnStart(sequence: sequence, error: error, blocks: blocks)
            }
        }
    }

    private func flushQueue() {
        guard isReady, !queuePaused, !hasExited,
              pendingTurnStartSequence == nil,
              let threadID = sessionID,
              !isWorking,
              !queuedMessages.isEmpty
        else { return }
        send(blocks: queuedMessages.removeFirst(), threadID: threadID)
    }

    private func finishTurnStart(sequence: Int, result: JSONValue) {
        guard pendingTurnStartSequence == sequence else { return }
        pendingTurnStartSequence = nil
        // A very short turn can complete before this request continuation is
        // resumed. Do not resurrect it after `turn/completed` cleared it.
        if isWorking, currentTurnID == nil {
            currentTurnID = result["turn"]?["id"]?.stringValue
            deliverPendingInterruptIfPossible()
        } else if !isWorking {
            flushQueue()
        }
    }

    private func failTurnStart(sequence: Int, error: Error, blocks: [UserContentBlock]) {
        guard pendingTurnStartSequence == sequence else { return }
        pendingTurnStartSequence = nil
        if let failure = error as? CodexAppServerClient.Failure, failure == .notRunning {
            queuedMessages.insert(blocks, at: 0)
        }
        // Once the request was written, a transport failure cannot tell us
        // whether Codex accepted it. Never put the text back in the queue and
        // risk running the same user turn twice after recovery.
        reportFailure(error)
    }

    @discardableResult
    func removeQueuedMessage(at index: Int) -> [UserContentBlock]? {
        guard queuedMessages.indices.contains(index) else { return nil }
        return queuedMessages.remove(at: index)
    }

    /// A control request, never a signal — a signal abandons the turn instead
    /// of ending it.
    func interrupt() {
        guard isWorking, sessionID != nil else { return }
        interruptRequested = true
        deliverPendingInterruptIfPossible()
    }

    private func deliverPendingInterruptIfPossible() {
        guard interruptRequested,
              let threadID = sessionID,
              let turnID = currentTurnID
        else { return }
        interruptRequested = false
        Task {
            _ = try? await client.send("turn/interrupt", .object([
                "threadId": .string(threadID),
                "turnId": .string(turnID)
            ]))
        }
    }

    func failToLaunch(reason: String) {
        lastError = reason
        hasExited = true
        isWorking = false
        StatusEngine.shared.setStatus(.error, taskID: taskID, tabID: tabID, notifiable: hasUserSubmitted)
    }

    func stop() {
        titleTask?.cancel()
        titleTask = nil
        Task {
            await CodexItemStore.shared.flush(tabID: tabID)
            await CodexSubagentStore.shared.flush(tabID: tabID)
        }
        if !client.usesSharedServer { remoteControl.stop() }
        backgroundTasks.stop()
        CodexSubagentStore.shared.connectionClosed(tabID: tabID)
        isReady = false
        isWorking = false
        pendingPermissions.removeAll()
        permissionRequestIDs.removeAll()
        permissionKinds.removeAll()
        childFileChanges.removeAll()
        clearForeignRouting()
        for task in childHydrations.values { task.cancel() }
        childHydrations.removeAll()
        attemptedChildHydrations.removeAll()
        failedChildHydrations.removeAll()
        interruptRequested = false
        if let sessionID { client.releaseThread(threadID: sessionID, turnID: currentTurnID) }
        client.stop()
        hasExited = true
    }

    // MARK: - Settings

    func setPermissionMode(_ mode: PermissionMode) {
        Log.agent.error("Codex has no equivalent of Claude Code's permission modes")
    }

    func setPermissionProfile(_ profile: AgentPermissionPreset) {
        // Turn parameters are the single source of truth for the next send.
        // Keeping this local also avoids racing independent settings RPCs.
        selectedPermissionProfile = profile.id
    }

    func setModel(_ newModel: AgentModel) {
        model = newModel
        if let effort, !CodexCatalogStore.shared.efforts(for: tabID, modelID: newModel.id).contains(effort) {
            self.effort = CodexCatalogStore.shared.defaultEffort(for: tabID, modelID: newModel.id)
        }
    }

    func setEffort(_ newEffort: AgentEffort) {
        effort = newEffort
    }

    func setCollaborationMode(_ mode: CodexCollaborationMode) {
        collaborationMode = mode
    }

    private func collaborationModeValue() -> JSONValue? {
        guard let model else { return nil }
        return .object([
            "mode": .string(collaborationMode.rawValue),
            "settings": .object([
                "model": .string(model.id),
                "reasoning_effort": effort.map { .string($0.rawValue) } ?? .null,
                "developer_instructions": .null
            ])
        ])
    }

    // MARK: - Answering

    func resolve(_ permission: PendingPermission, with decision: PermissionDecision) {
        guard let id = permissionRequestIDs.removeValue(forKey: permission.id) else { return }
        let kind = permissionKinds.removeValue(forKey: permission.id) ?? .decision
        if case .permissions(let requested) = kind {
            let granted: JSONValue = switch decision {
            case .allow: requested
            case .deny: .object([:])
            }
            client.respond(to: id, result: .object([
                "permissions": granted,
                "scope": .string("turn")
            ]))
            pendingPermissions.removeAll { $0.id == permission.id }
            reportPendingPermissions()
            return
        }
        // Codex's decisions are a closed set with no free-text field, so a
        // denial's message has nowhere to go.
        let verdict: String = switch decision {
        case .allow: "accept"
        case .deny: "decline"
        }
        client.respond(to: id, result: .object(["decision": .string(verdict)]))
        pendingPermissions.removeAll { $0.id == permission.id }
        reportPendingPermissions()
    }

    func resolve(_ permission: PendingPermission, with option: PermissionDecisionOption) {
        guard let id = permissionRequestIDs.removeValue(forKey: permission.id) else { return }
        let kind = permissionKinds.removeValue(forKey: permission.id) ?? .decision
        if case .permissions(let requested) = kind {
            client.respond(to: id, result: .object([
                "permissions": option.allowsAction ? requested : .object([:]),
                "scope": .string(option.id == "session" ? "session" : "turn")
            ]))
        } else {
            client.respond(to: id, result: .object(["decision": .string(option.id)]))
        }
        pendingPermissions.removeAll { $0.id == permission.id }
        reportPendingPermissions()
    }

    func approvePlan(_ permission: PendingPermission) {
        Log.agent.error("Codex plan proposals are reviewed through a new turn, not a permission response")
    }

    func approvePlan(_ permission: PendingPermission, feedback: String) {
        approvePlan(permission)
    }

    @discardableResult
    func implementPlan(feedback: String = "") -> Bool {
        guard planProposal != nil, !isWorking, !hasExited else { return false }
        collaborationMode = .default
        planProposal = nil
        let feedback = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
        submit(text: feedback.isEmpty
            ? "Implement the proposed plan."
            : "Implement the proposed plan with this feedback:\n\n\(feedback)")
        return true
    }

    @discardableResult
    func requestPlanChanges(_ feedback: String) -> Bool {
        guard planProposal != nil, !isWorking, !hasExited else { return false }
        collaborationMode = .plan
        planProposal = nil
        let feedback = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
        submit(text: feedback.isEmpty
            ? "Revise the proposed plan and present a new proposal."
            : "Revise the proposed plan with this feedback:\n\n\(feedback)")
        return true
    }

    func answer(_ permission: PendingPermission, answers: [String: String]) {
        guard let id = permissionRequestIDs.removeValue(forKey: permission.id) else { return }
        permissionKinds.removeValue(forKey: permission.id)
        var mapped: [String: JSONValue] = [:]
        if case .questions(let questions)? = permission.interactive {
            for question in questions {
                guard let answer = answers[question.question] ?? answers[question.id] else { continue }
                let values = question.multiSelect
                    ? answer.components(separatedBy: ", ")
                    : [answer]
                mapped[question.id] = .object([
                    "answers": .array(values.map(JSONValue.string))
                ])
            }
        }
        client.respond(to: id, result: .object(["answers": .object(mapped)]))
        pendingPermissions.removeAll { $0.id == permission.id }
        reportPendingPermissions()
    }

    // MARK: - Incoming

    private func handle(notification method: String, params: JSONValue) {
        guard !hasExited, !client.usesSharedServer || hasStartedHandshake else { return }
        if let incomingThreadID = threadID(in: params) {
            guard let sessionID else {
                if hasStartedHandshake {
                    deferredInbound.append(.notification(method, params))
                    return
                }
                route(notification: method, params: params)
                return
            }
            if incomingThreadID != sessionID {
                guard knownChildThreadIDs.contains(incomingThreadID) else {
                    validateForeign(.notification(method, params), threadID: incomingThreadID,
                                    metadata: method == "thread/started" ? params["thread"] : nil)
                    return
                }
                if method == "serverRequest/resolved" {
                    route(notification: method, params: params)
                } else {
                    captureChildFileChange(method: method, params: params, threadID: incomingThreadID)
                    routeChild(notification: method, params: params, threadID: incomingThreadID)
                }
                return
            }
        }
        route(notification: method, params: params)
    }

    /// App-server broadcasts thread metadata even to unsubscribed clients.
    /// A foreign ID is not a subagent until its ancestry reaches this tab.
    private func validateForeign(_ event: DeferredInbound, threadID: String, metadata: JSONValue? = nil) {
        guard !hasExited, let rootID = sessionID, !unrelatedThreadIDs.contains(threadID) else { return }
        if let metadata, subagentParent(in: metadata) == nil {
            rejectForeign(threadID)
            return
        }
        guard foreignInbound[threadID] != nil || foreignInbound.count < 16 else { return }
        // Bound both concurrent lookups and retained streaming data. Normally
        // thread/started or the parent's spawn item establishes identity first.
        if foreignInbound[threadID, default: []].count < 128 {
            foreignInbound[threadID, default: []].append(event)
        }
        guard ancestryReads[threadID] == nil else { return }
        ancestryReads[threadID] = Task { [weak self] in
            guard let self else { return }
            defer { ancestryReads.removeValue(forKey: threadID) }
            do {
                var currentID = threadID
                var currentMetadata = metadata
                var visited: Set<String> = []
                for _ in 0..<16 {
                    guard visited.insert(currentID).inserted else { break }
                    if currentMetadata == nil {
                        let result = try await client.send("thread/read", .object([
                            "threadId": .string(currentID), "includeTurns": .bool(false)
                        ]))
                        currentMetadata = result["thread"]
                    }
                    guard !Task.isCancelled, !hasExited, sessionID == rootID else { return }
                    guard let parent = subagentParent(in: currentMetadata ?? .null) else { break }
                    if parent == rootID || knownChildThreadIDs.contains(parent) {
                        for id in visited { acceptChild(id) }
                        return
                    }
                    currentID = parent
                    currentMetadata = nil
                }
                rejectForeign(threadID)
            } catch {
                // No proof of ownership: leave other clients' requests alone.
                // A later parent spawn item can still establish the child.
                foreignInbound.removeValue(forKey: threadID)
            }
        }
    }

    private func subagentParent(in thread: JSONValue) -> String? {
        thread["source"]?["subAgent"]?["thread_spawn"]?["parent_thread_id"]?.stringValue
    }

    private func acceptChild(_ threadID: String) {
        guard threadID != sessionID else { return }
        knownChildThreadIDs.insert(threadID)
        unrelatedThreadIDs.remove(threadID)
        let inbound = foreignInbound.removeValue(forKey: threadID) ?? []
        for event in inbound {
            switch event {
            case .notification(let method, let params): handle(notification: method, params: params)
            case .request(let id, let method, let params): handle(request: id, method: method, params: params)
            }
        }
    }

    private func rejectForeign(_ threadID: String) {
        foreignInbound.removeValue(forKey: threadID)
        if unrelatedThreadIDs.count < 256 { unrelatedThreadIDs.insert(threadID) }
    }

    private func clearForeignRouting() {
        for task in ancestryReads.values { task.cancel() }
        ancestryReads.removeAll()
        foreignInbound.removeAll()
        knownChildThreadIDs.removeAll()
        unrelatedThreadIDs.removeAll()
    }

    private func captureChildFileChange(method: String, params: JSONValue, threadID: String) {
        guard method == "item/started"
                || method == "item/completed"
                || method == "item/fileChange/patchUpdated",
              let itemID = params["itemId"]?.stringValue ?? params["item"]?["id"]?.stringValue,
              let turnID = params["turnId"]?.stringValue
        else { return }

        let changes: JSONValue?
        if method == "item/fileChange/patchUpdated" {
            changes = params["changes"]
        } else if params["item"]?["type"]?.stringValue == "fileChange" {
            changes = params["item"]?["changes"]
        } else {
            changes = nil
        }
        guard let changes else { return }
        childFileChanges[ChildFileChangeKey(threadID: threadID, turnID: turnID, itemID: itemID)] = changes
    }

    private func routeChild(notification method: String, params: JSONValue, threadID: String) {
        switch method {
        case "thread/status/changed":
            hydrateChild(threadID: threadID, retry: params["status"]?["type"]?.stringValue == "active")
            CodexSubagentStore.shared.receiveThreadMetadata(
                tabID: tabID, threadID: threadID,
                thread: .object(["status": params["status"] ?? .null])
            )
        case "turn/started":
            hydrateChild(threadID: threadID, retry: true)
            CodexSubagentStore.shared.receiveTurnLifecycle(tabID: tabID, threadID: threadID, working: true)
        case "turn/completed":
            hydrateChild(threadID: threadID)
            backgroundTasks.refresh(threadID: threadID)
            CodexSubagentStore.shared.receiveTurnLifecycle(tabID: tabID, threadID: threadID, working: false, status: params["turn"]?["status"]?.stringValue)
        case "item/started", "item/completed":
            hydrateChild(threadID: threadID)
            guard let item = params["item"] else { return }
            if item["type"]?.stringValue == "commandExecution" {
                backgroundTasks.refresh(threadID: threadID)
            }
            CodexSubagentStore.shared.receiveChildItem(tabID: tabID, threadID: threadID, item: item, turnID: params["turnId"]?.stringValue, lifecycle: method == "item/started" ? .started : .completed)
            discoverSubagents(in: item)
        case "item/agentMessage/delta", "item/plan/delta":
            guard let itemID = params["itemId"]?.stringValue else { return }
            CodexSubagentStore.shared.appendText(tabID: tabID, threadID: threadID, itemID: itemID, turnID: params["turnId"]?.stringValue, type: method == "item/plan/delta" ? "plan" : "agentMessage", field: "text", delta: params["delta"]?.stringValue ?? "")
        case "item/reasoning/textDelta", "item/reasoning/summaryTextDelta":
            guard let itemID = params["itemId"]?.stringValue else { return }
            let summary = method == "item/reasoning/summaryTextDelta"
            CodexSubagentStore.shared.appendText(tabID: tabID, threadID: threadID, itemID: itemID, turnID: params["turnId"]?.stringValue, type: "reasoning", field: summary ? "summary" : "content", index: params[summary ? "summaryIndex" : "contentIndex"]?.intValue ?? 0, delta: params["delta"]?.stringValue ?? "")
        case "item/commandExecution/outputDelta":
            guard let itemID = params["itemId"]?.stringValue else { return }
            CodexSubagentStore.shared.append(tabID: tabID, threadID: threadID, itemID: itemID, turnID: params["turnId"]?.stringValue, field: "aggregatedOutput", delta: params["delta"]?.stringValue ?? "")
        case "item/fileChange/patchUpdated":
            guard let itemID = params["itemId"]?.stringValue, let changes = params["changes"] else { return }
            CodexSubagentStore.shared.set(tabID: tabID, threadID: threadID, itemID: itemID, turnID: params["turnId"]?.stringValue, field: "changes", value: changes)
        default: break
        }
    }

    private func route(notification method: String, params: JSONValue) {
        switch method {
        case "remoteControl/status/changed":
            remoteControl.receive(params)
        case "skills/changed":
            Task { await refreshSkills() }
        case "thread/name/updated":
            if let title = CodexThreadTitle.name(params["threadName"]?.stringValue) {
                hasServerTitle = true
                serverTitle = title
                titleRevision += 1
                TitleStore.shared.setTitle(title, forTab: tabID)
            }
        case "thread/started":
            break
        case "turn/started":
            currentTurnID = params["turn"]?["id"]?.stringValue
            isWorking = true
            streamingText = ""
            streamingThinking = ""
            StatusEngine.shared.setStatus(.working, taskID: taskID, tabID: tabID)
            deliverPendingInterruptIfPossible()
        case "turn/completed":
            if let sessionID { backgroundTasks.refresh(threadID: sessionID) }
            endTurn(params["turn"] ?? .null)
            Task {
                await CodexItemStore.shared.flush(tabID: tabID)
                await CodexSubagentStore.shared.flush(tabID: tabID)
            }
        case "item/agentMessage/delta":
            if let itemID = params["itemId"]?.stringValue {
                CodexItemStore.shared.appendText(
                    tabID: tabID, itemID: itemID, turnID: params["turnId"]?.stringValue,
                    type: "agentMessage", field: "text",
                    delta: params["delta"]?.stringValue ?? ""
                )
            }
        case "item/reasoning/textDelta", "item/reasoning/summaryTextDelta":
            if let itemID = params["itemId"]?.stringValue {
                let isSummary = method == "item/reasoning/summaryTextDelta"
                CodexItemStore.shared.appendText(
                    tabID: tabID, itemID: itemID, turnID: params["turnId"]?.stringValue,
                    type: "reasoning",
                    field: isSummary ? "summary" : "content",
                    index: params[isSummary ? "summaryIndex" : "contentIndex"]?.intValue ?? 0,
                    delta: params["delta"]?.stringValue ?? ""
                )
            }
        case "item/plan/delta":
            if let itemID = params["itemId"]?.stringValue {
                CodexItemStore.shared.appendText(
                    tabID: tabID, itemID: itemID, turnID: params["turnId"]?.stringValue,
                    type: "plan", field: "text",
                    delta: params["delta"]?.stringValue ?? ""
                )
            }
        case "thread/tokenUsage/updated":
            let usage = params["tokenUsage"]
            contextWindow = usage?["modelContextWindow"]?.intValue
            contextUsedTokens = usage?["last"]?["totalTokens"]?.intValue
        case "account/rateLimits/updated":
            rateLimit = accountRateLimits.receive(params)
            CodexQuotaStore.shared.record(params)
        case "error":
            lastError = params["error"]?["message"]?.stringValue
            // A retry is still the same turn in flight, so it is not a failure
            // the user has to act on.
            if params["willRetry"] != .bool(true) {
                isWorking = false
                currentTurnID = nil
                interruptRequested = false
                queuePaused = true
                StatusEngine.shared.setStatus(.error, taskID: taskID, tabID: tabID, notifiable: hasUserSubmitted)
            }
        case "serverRequest/resolved":
            dropPermission(requestID: params["requestId"])
        case "item/started", "item/completed":
            if let item = params["item"] {
                if item["type"]?.stringValue == "commandExecution", let sessionID {
                    backgroundTasks.refresh(threadID: sessionID)
                }
                discoverSubagents(in: item)
                let lifecycle: CodexItemStore.ItemLifecycle = method == "item/started" ? .started : .completed
                CodexItemStore.shared.upsert(
                    tabID: tabID,
                    item: item,
                    turnID: params["turnId"]?.stringValue,
                    lifecycle: lifecycle
                )
                if lifecycle == .completed, item["type"]?.stringValue == "plan" {
                    planProposal = CodexItemStore.shared.latestPendingPlan(forTab: tabID)
                }
            }
        case "item/commandExecution/outputDelta":
            if let itemID = params["itemId"]?.stringValue {
                CodexItemStore.shared.append(
                    tabID: tabID,
                    itemID: itemID,
                    turnID: params["turnId"]?.stringValue,
                    field: "aggregatedOutput",
                    delta: params["delta"]?.stringValue ?? ""
                )
            }
        case "item/fileChange/patchUpdated":
            if let itemID = params["itemId"]?.stringValue, let changes = params["changes"] {
                CodexItemStore.shared.set(
                    tabID: tabID,
                    itemID: itemID,
                    turnID: params["turnId"]?.stringValue,
                    field: "changes",
                    value: changes
                )
            }
        default:
            break
        }
    }

    private func endTurn(_ turn: JSONValue) {
        let completedID = turn["id"]?.stringValue
        if let currentTurnID, let completedID, currentTurnID != completedID { return }
        isWorking = false
        currentTurnID = nil
        interruptRequested = false
        pendingPermissions.removeAll()
        permissionKinds.removeAll()
        permissionRequestIDs.removeAll()
        switch turn["status"]?.stringValue {
        case "failed":
            queuePaused = true
            lastError = turn["error"]?["message"]?.stringValue
            StatusEngine.shared.setStatus(.error, taskID: taskID, tabID: tabID, notifiable: hasUserSubmitted)
        case "interrupted":
            queuePaused = true
            StatusEngine.shared.setStatus(.interrupted, taskID: taskID, tabID: tabID)
        default:
            StatusEngine.shared.setStatus(.awaitingReply, taskID: taskID, tabID: tabID)
            if pendingTurnStartSequence == nil { flushQueue() }
            requestTitleIfDue()
        }
    }

    private func requestTitleIfDue() {
        guard titleTask == nil, let threadID = sessionID,
              let context = titleContextProvider?(tabID) else { return }
        let plan = planProposal
        let description = titleRequester.descriptionForTitleRequest(.init(
            transport: context.transport, userTaskName: context.userTaskName,
            isWorking: isWorking, openingMessage: openingMessage,
            planFilePath: plan?.id, planTitle: plan.flatMap { PlanSummary.title(of: $0.markdown) },
            hasExistingTitle: hasServerTitle
        ))
        guard let description else { return }
        let revision = titleRevision
        titleTask = Task { [weak self, generateTitle] in
            let title = await generateTitle(description)
            guard let self else { return }
            defer { self.titleTask = nil }
            guard !Task.isCancelled, !self.hasExited,
                  self.sessionID == threadID, self.titleRevision == revision,
                  let context = self.titleContextProvider?(self.tabID),
                  context.userTaskName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true,
                  let title else { return }
            do {
                _ = try await self.client.send("thread/name/set", .object([
                    "threadId": .string(threadID), "name": .string(title)
                ]))
                guard !Task.isCancelled, !self.hasExited,
                      self.titleRevision == revision || self.serverTitle == title,
                      let context = self.titleContextProvider?(self.tabID),
                      context.userTaskName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
                else { return }
                self.hasServerTitle = true
                self.serverTitle = title
                TitleStore.shared.setTitle(title, forTab: self.tabID)
            } catch { /* A title failure must never fail the user's turn. */ }
        }
    }

    private func handle(request id: CodexRPC.RequestID, method: String, params: JSONValue) {
        guard !hasExited, !client.usesSharedServer || hasStartedHandshake else { return }
        if let incomingThreadID = threadID(in: params) {
            guard let sessionID else {
                if hasStartedHandshake {
                    deferredInbound.append(.request(id, method, params))
                    return
                }
                route(request: id, method: method, params: params, agentID: nil)
                return
            }
            guard incomingThreadID == sessionID else {
                guard knownChildThreadIDs.contains(incomingThreadID) else {
                    validateForeign(.request(id, method, params), threadID: incomingThreadID)
                    return
                }
                if isApprovalMethod(method) {
                    route(request: id, method: method, params: params, agentID: incomingThreadID)
                } else {
                    client.respondUnsupported(to: id, method: method)
                }
                return
            }
        }
        route(request: id, method: method, params: params, agentID: nil)
    }

    private func isApprovalMethod(_ method: String) -> Bool {
        switch method {
        case "item/commandExecution/requestApproval",
             "item/fileChange/requestApproval",
             "item/permissions/requestApproval",
             "item/tool/requestUserInput":
            return true
        default:
            return false
        }
    }

    private func route(
        request id: CodexRPC.RequestID,
        method: String,
        params: JSONValue,
        agentID: String?
    ) {
        switch method {
        case "item/commandExecution/requestApproval":
            enqueue(permission: commandPermission(params, agentID: agentID), id: id)
        case "item/fileChange/requestApproval":
            enqueue(permission: fileChangePermission(params, agentID: agentID), id: id)
        case "item/permissions/requestApproval":
            let permission = expandedPermissionsPermission(params, agentID: agentID)
            enqueue(
                permission: permission,
                id: id,
                kind: .permissions(params["permissions"] ?? .object([:]))
            )
        case "item/tool/requestUserInput":
            enqueue(permission: questionPermission(params, agentID: agentID), id: id, kind: .question)
        default:
            // Every server request must be answered, or the turn stalls.
            client.respondUnsupported(to: id, method: method)
        }
    }

    private func enqueue(
        permission: PendingPermission,
        id: CodexRPC.RequestID,
        kind: PermissionRequestKind = .decision
    ) {
        let key = permissionKey(id)
        guard permissionRequestIDs[key] == nil else { return }
        let keyedPermission = PendingPermission(
            id: key,
            toolName: permission.toolName,
            displayName: permission.displayName,
            input: permission.input,
            description: permission.description,
            decisionReason: permission.decisionReason,
            toolUseID: permission.toolUseID,
            agentID: permission.agentID,
            interactive: permission.interactive,
            decisions: permission.decisions
        )
        permissionRequestIDs[key] = id
        permissionKinds[key] = kind
        pendingPermissions.append(keyedPermission)
        reportPendingPermissions()
    }

    /// Request IDs are JSON-RPC values, so numeric 5 and string "5" are
    /// distinct approval requests even though both have the same display text.
    private func permissionKey(_ id: CodexRPC.RequestID) -> String {
        switch id {
        case .number(let value): "number:\(value)"
        case .string(let value): "string:\(value)"
        }
    }

    private func toolUseID(in params: JSONValue) -> String? {
        guard let itemID = params["itemId"]?.stringValue else { return nil }
        guard let turnID = params["turnId"]?.stringValue, !turnID.isEmpty else { return itemID }
        return "\(turnID)#\(itemID)"
    }

    private func reportPendingPermissions() {
        guard !hasExited else { return }
        var status: TaskStatus?
        for permission in pendingPermissions {
            let candidate: TaskStatus = switch permission.interactive {
            case .plan: .planApproval
            case .questions: .questionAsked
            case nil: .permissionNeeded
            }
            if candidate.priority > (status?.priority ?? -1) { status = candidate }
        }
        StatusEngine.shared.setStatus(
            status ?? (isWorking ? .working : .awaitingReply),
            taskID: taskID,
            tabID: tabID
        )
    }

    private func threadID(in params: JSONValue) -> String? {
        params["threadId"]?.stringValue ?? params["thread"]?["id"]?.stringValue
    }

    private func drainDeferredInbound() {
        let inbound = deferredInbound
        deferredInbound.removeAll()
        for event in inbound {
            switch event {
            case .notification(let method, let params): handle(notification: method, params: params)
            case .request(let id, let method, let params): handle(request: id, method: method, params: params)
            }
        }
    }

    private func expandedPermissionsPermission(_ params: JSONValue, agentID: String?) -> PendingPermission {
        let itemID = params["itemId"]?.stringValue ?? UUID().uuidString
        return PendingPermission(
            id: itemID,
            toolName: "Permissions",
            displayName: "Expand permissions",
            input: ["permissions": params["permissions"] ?? .object([:])],
            description: params["reason"]?.stringValue,
            decisionReason: nil,
            toolUseID: toolUseID(in: params),
            agentID: agentID,
            interactive: nil,
            decisions: [
                .init(id: "turn", label: "Allow for Turn", allowsAction: true),
                .init(id: "session", label: "Allow for Session", allowsAction: true),
                .init(id: "decline", label: "Deny", allowsAction: false)
            ]
        )
    }

    private func questionPermission(_ params: JSONValue, agentID: String?) -> PendingPermission {
        let itemID = params["itemId"]?.stringValue ?? UUID().uuidString
        let questions = params["questions"]?.arrayValue?.compactMap { value -> InteractiveToolPayload.AskedQuestion? in
            guard let id = value["id"]?.stringValue,
                  let question = value["question"]?.stringValue
            else { return nil }
            let options = value["options"]?.arrayValue?.compactMap { option -> InteractiveToolPayload.AskedQuestion.Option? in
                guard let label = option["label"]?.stringValue else { return nil }
                return .init(label: label, description: option["description"]?.stringValue ?? "")
            } ?? []
            return .init(
                id: id,
                header: value["header"]?.stringValue ?? "",
                question: question,
                multiSelect: false,
                options: options
            )
        } ?? []
        return PendingPermission(
            id: itemID,
            toolName: "RequestUserInput",
            displayName: "Question",
            input: [:],
            description: nil,
            decisionReason: nil,
            toolUseID: toolUseID(in: params),
            agentID: agentID,
            interactive: questions.isEmpty ? nil : .questions(questions)
        )
    }

    private func commandPermission(_ params: JSONValue, agentID: String?) -> PendingPermission {
        let command = params["command"]?.stringValue ?? ""
        return PendingPermission(
            id: params["itemId"]?.stringValue ?? UUID().uuidString,
            toolName: "Shell",
            displayName: "Run command",
            input: ["command": .string(command)],
            description: command,
            decisionReason: params["reason"]?.stringValue,
            toolUseID: toolUseID(in: params),
            agentID: agentID,
            interactive: nil,
            decisions: decisionOptions(in: params, fallback: ["accept", "decline"])
        )
    }

    /// The patch is not in the request — it arrived earlier on the item this
    /// names, which Plume does not track yet.
    private func fileChangePermission(_ params: JSONValue, agentID: String?) -> PendingPermission {
        let itemID = params["itemId"]?.stringValue ?? UUID().uuidString
        let turnID = params["turnId"]?.stringValue
        let input: [String: JSONValue]
        if let agentID,
           let turnID,
           let changes = childFileChanges[ChildFileChangeKey(threadID: agentID, turnID: turnID, itemID: itemID)] {
            // Keep the server's raw change payload for child approvals. The
            // child item is intentionally absent from the root item store.
            input = ["changes": changes]
        } else {
            input = CodexItemStore.shared.fileChangeInput(
                tabID: tabID,
                itemID: itemID,
                turnID: turnID
            )
        }
        return PendingPermission(
            id: itemID,
            toolName: "Edit",
            displayName: "Apply file changes",
            input: input,
            description: nil,
            decisionReason: params["reason"]?.stringValue,
            toolUseID: toolUseID(in: params),
            agentID: agentID,
            interactive: nil,
            decisions: decisionOptions(
                in: params,
                fallback: ["accept", "acceptForSession", "decline", "cancel"]
            )
        )
    }

    private func decisionOptions(in params: JSONValue, fallback: [String]) -> [PermissionDecisionOption] {
        let ids = params["availableDecisions"]?.arrayValue?.compactMap(\.stringValue) ?? fallback
        return ids.map { id in
            PermissionDecisionOption(
                id: id,
                label: decisionLabel(id),
                allowsAction: id == "accept" || id == "acceptForSession"
            )
        }
    }

    private func decisionLabel(_ id: String) -> String {
        switch id {
        case "accept": "Allow"
        case "acceptForSession": "Allow for Session"
        case "decline": "Deny"
        case "cancel": "Cancel"
        default: id
        }
    }

    private func dropPermission(requestID: JSONValue?) {
        guard let requestID, let id = CodexRPC.RequestID(json: requestID) else { return }
        let key = permissionKey(id)
        guard permissionRequestIDs.removeValue(forKey: key) != nil else { return }
        permissionKinds.removeValue(forKey: key)
        pendingPermissions.removeAll { $0.id == key }
        reportPendingPermissions()
    }

    private func reportFailure(_ error: Error) {
        isWorking = false
        interruptRequested = false
        queuePaused = true
        lastError = (error as? CodexAppServerClient.Failure).map(String.init(describing:))
            ?? error.localizedDescription
        StatusEngine.shared.setStatus(.error, taskID: taskID, tabID: tabID, notifiable: hasUserSubmitted)
    }

    private func handleExit(status: Int32, message: String?) {
        titleTask?.cancel()
        titleTask = nil
        clearForeignRouting()
        if !client.usesSharedServer { remoteControl.stop() }
        backgroundTasks.stop()
        CodexSubagentStore.shared.connectionClosed(tabID: tabID)
        hasExited = true
        exitStatus = status
        isWorking = false
        isReady = false
        pendingTurnStartSequence = nil
        interruptRequested = false
        pendingPermissions.removeAll()
        permissionRequestIDs.removeAll()
        permissionKinds.removeAll()
        childFileChanges.removeAll()
        if let message { lastError = message }
        if lastError == nil { lastError = "Codex disconnected. Reconnect to resume this conversation." }
        // Explicit `stop()` suppresses AgentProcess's exit callback. Any exit
        // that reaches here is an unexpected loss of the app-server, even if
        // the subprocess happened to return zero.
        StatusEngine.shared.setStatus(.error, taskID: taskID, tabID: tabID, notifiable: hasUserSubmitted)
    }

    private enum SessionFailure: Error {
        case missingThreadID
    }
}
