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
    let tabID: UUID
    let taskID: UUID

    private(set) var sessionID: String?
    private(set) var isWorking = false
    private(set) var hasExited = false
    private(set) var exitStatus: Int32?
    private(set) var pendingPermissions: [PendingPermission] = []
    private(set) var streamingText = ""
    private(set) var streamingThinking = ""
    private(set) var rateLimit: RateLimitInfo?
    /// Codex reports tokens, never dollars.
    let sessionCostUSD: Double? = nil
    private(set) var contextWindow: Int?
    private(set) var contextUsedTokens: Int?
    var nominalContextWindow: Int? { nil }
    /// `initialize` returns no command list, and `skills/list` is a different
    /// vocabulary, so the composer offers no completions on a Codex tab.
    let slashCommands: [SlashCommand] = []
    private(set) var lastError: String?
    private(set) var permissionMode: PermissionMode?
    private(set) var model: AgentModel?
    private(set) var effort: AgentEffort?
    private(set) var hasReportedModeAndModel = false
    private(set) var queuedMessages: [String] = []

    /// Codex's `plan` item is a running TODO list the model maintains, not a
    /// proposal that blocks on approval.
    let supportsPlanApproval = false

    private let client: CodexAppServerClient
    /// `turn/interrupt` is addressed to a specific turn, so the id from
    /// `turn/started` has to be kept.
    private var currentTurnID: String?
    /// Approval requests are answered by the ID that carried them.
    private var permissionRequestIDs: [String: CodexRPC.RequestID] = [:]

    init(tabID: UUID, taskID: UUID, initialEffort: AgentEffort? = nil, client: CodexAppServerClient? = nil) {
        let client = client ?? CodexAppServerClient()
        self.tabID = tabID
        self.taskID = taskID
        self.effort = initialEffort
        self.client = client
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
        permissionProfile: String? = nil,
        environment: [String: String]
    ) {
        if let model { self.model = model }
        do {
            try client.start(workingDirectory: workingDirectory, environment: environment)
        } catch {
            Log.agent.error("Codex launch failed: \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
            hasExited = true
            StatusEngine.shared.setStatus(.error, taskID: taskID, tabID: tabID)
            return
        }
        Task {
            await handshake(
                workingDirectory: workingDirectory,
                resumeThreadID: resumeThreadID,
                permissionProfile: permissionProfile
            )
        }
    }

    private func handshake(
        workingDirectory: String?,
        resumeThreadID: String?,
        permissionProfile: String?
    ) async {
        do {
            _ = try await client.send("initialize", .object([
                "clientInfo": .object([
                    "name": .string("Plume"),
                    "title": .string("Plume"),
                    "version": .string(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0")
                ]),
                "capabilities": .object([
                    "optOutNotificationMethods": .array(
                        CodexCommand.ignoredNotifications.map(JSONValue.string)
                    )
                ])
            ]))
            client.notify("initialized")

            var params: [String: JSONValue] = [:]
            if let workingDirectory { params["cwd"] = .string(workingDirectory) }
            if let model { params["model"] = .string(model.id) }
            if let permissionProfile { params["permissions"] = .string(permissionProfile) }
            let method: String
            if let resumeThreadID, !resumeThreadID.isEmpty {
                method = "thread/resume"
                params["threadId"] = .string(resumeThreadID)
            } else {
                method = "thread/start"
            }
            let result = try await client.send(method, .object(params))
            adopt(thread: result["thread"] ?? .null)
            if let threadID = sessionID {
                await hydrateHistory(threadID: threadID)
            }
            flushQueue()
        } catch {
            reportFailure(error)
        }
    }

    private func adopt(thread: JSONValue) {
        if let id = thread["id"]?.stringValue { sessionID = id }
        if let reported = thread["model"]?.stringValue {
            model = AgentModel(id: reported, label: reported)
        }
        if let reported = thread["reasoningEffort"]?.stringValue {
            effort = AgentEffort(rawValue: reported)
        }
        hasReportedModeAndModel = true
    }

    private func hydrateHistory(threadID: String) async {
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
        CodexItemStore.shared.replace(tabID: tabID, items: items)
    }

    // MARK: - Sending

    func submit(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let threadID = sessionID, !isWorking else {
            queuedMessages.append(trimmed)
            return
        }
        send(text: trimmed, threadID: threadID)
    }

    private func send(text: String, threadID: String) {
        streamingText = ""
        streamingThinking = ""
        isWorking = true
        StatusEngine.shared.setStatus(.working, taskID: taskID, tabID: tabID)
        var params: [String: JSONValue] = [
            "threadId": .string(threadID),
            "input": .array([.object(["type": .string("text"), "text": .string(text)])])
        ]
        if let effort { params["effort"] = .string(effort.rawValue) }
        Task {
            do {
                _ = try await client.send("turn/start", .object(params))
            } catch {
                reportFailure(error)
            }
        }
    }

    private func flushQueue() {
        guard let threadID = sessionID, !isWorking, !queuedMessages.isEmpty else { return }
        send(text: queuedMessages.removeFirst(), threadID: threadID)
    }

    @discardableResult
    func removeQueuedMessage(at index: Int) -> String? {
        guard queuedMessages.indices.contains(index) else { return nil }
        return queuedMessages.remove(at: index)
    }

    /// A control request, never a signal — a signal abandons the turn instead
    /// of ending it.
    func interrupt() {
        guard let threadID = sessionID, let turnID = currentTurnID else { return }
        Task {
            _ = try? await client.send("turn/interrupt", .object([
                "threadId": .string(threadID),
                "turnId": .string(turnID)
            ]))
        }
    }

    func stop() {
        client.stop()
        hasExited = true
    }

    // MARK: - Settings

    func setPermissionMode(_ mode: PermissionMode) {
        Log.agent.error("Codex has no equivalent of Claude Code's permission modes")
    }

    func setPermissionProfile(_ profile: AgentPermissionPreset) {
        guard let threadID = sessionID else { return }
        Task {
            _ = try? await client.send("thread/settings/update", .object([
                "threadId": .string(threadID),
                "permissions": .string(profile.id)
            ]))
        }
    }

    func setModel(_ newModel: AgentModel) {
        model = newModel
        guard let threadID = sessionID else { return }
        Task {
            _ = try? await client.send("thread/settings/update", .object([
                "threadId": .string(threadID),
                "model": .string(newModel.id)
            ]))
        }
    }

    func setEffort(_ newEffort: AgentEffort) {
        effort = newEffort
        guard let threadID = sessionID else { return }
        Task {
            _ = try? await client.send("thread/settings/update", .object([
                "threadId": .string(threadID),
                "effort": .string(newEffort.rawValue)
            ]))
        }
    }

    // MARK: - Answering

    func resolve(_ permission: PendingPermission, with decision: PermissionDecision) {
        guard let id = permissionRequestIDs.removeValue(forKey: permission.id) else { return }
        // Codex's decisions are a closed set with no free-text field, so a
        // denial's message has nowhere to go.
        let verdict: String = switch decision {
        case .allow: "accept"
        case .deny: "decline"
        }
        client.respond(to: id, result: .object(["decision": .string(verdict)]))
        pendingPermissions.removeAll { $0.id == permission.id }
    }

    func resolve(_ permission: PendingPermission, with option: PermissionDecisionOption) {
        guard let id = permissionRequestIDs.removeValue(forKey: permission.id) else { return }
        client.respond(to: id, result: .object(["decision": .string(option.id)]))
        pendingPermissions.removeAll { $0.id == permission.id }
    }

    func approvePlan(_ permission: PendingPermission) {
        Log.agent.error("Codex proposes no plans to approve")
    }

    func approvePlan(_ permission: PendingPermission, feedback: String) {
        approvePlan(permission)
    }

    func answer(_ permission: PendingPermission, answers: [String: String]) {
        guard let id = permissionRequestIDs.removeValue(forKey: permission.id) else { return }
        let mapped = answers.mapValues(JSONValue.string)
        client.respond(to: id, result: .object(["answers": .object(mapped)]))
        pendingPermissions.removeAll { $0.id == permission.id }
    }

    // MARK: - Incoming

    private func handle(notification method: String, params: JSONValue) {
        switch method {
        case "thread/started":
            adopt(thread: params["thread"] ?? .null)
        case "turn/started":
            currentTurnID = params["turn"]?["id"]?.stringValue
            isWorking = true
            streamingText = ""
            streamingThinking = ""
            StatusEngine.shared.setStatus(.working, taskID: taskID, tabID: tabID)
        case "turn/completed":
            endTurn(params["turn"] ?? .null)
        case "item/agentMessage/delta":
            streamingText += params["delta"]?.stringValue ?? ""
        case "item/reasoning/textDelta", "item/reasoning/summaryTextDelta":
            streamingThinking += params["delta"]?.stringValue ?? ""
        case "thread/tokenUsage/updated":
            let usage = params["tokenUsage"]
            contextWindow = usage?["modelContextWindow"]?.intValue
            contextUsedTokens = usage?["total"]?["totalTokens"]?.intValue
        case "error":
            lastError = params["error"]?["message"]?.stringValue
            // A retry is still the same turn in flight, so it is not a failure
            // the user has to act on.
            if params["willRetry"] != .bool(true) {
                isWorking = false
                StatusEngine.shared.setStatus(.error, taskID: taskID, tabID: tabID)
            }
        case "serverRequest/resolved":
            dropPermission(requestID: params["requestId"])
        case "item/started", "item/completed":
            if let item = params["item"] {
                CodexItemStore.shared.upsert(tabID: tabID, item: item)
            }
        case "item/commandExecution/outputDelta":
            if let itemID = params["itemId"]?.stringValue {
                CodexItemStore.shared.append(
                    tabID: tabID,
                    itemID: itemID,
                    field: "aggregatedOutput",
                    delta: params["delta"]?.stringValue ?? ""
                )
            }
        case "item/fileChange/patchUpdated":
            if let itemID = params["itemId"]?.stringValue, let changes = params["changes"] {
                CodexItemStore.shared.set(tabID: tabID, itemID: itemID, field: "changes", value: changes)
            }
        default:
            break
        }
    }

    private func endTurn(_ turn: JSONValue) {
        isWorking = false
        currentTurnID = nil
        switch turn["status"]?.stringValue {
        case "failed":
            lastError = turn["error"]?["message"]?.stringValue
            StatusEngine.shared.setStatus(.error, taskID: taskID, tabID: tabID)
        case "interrupted":
            StatusEngine.shared.setStatus(.idle, taskID: taskID, tabID: tabID)
        default:
            StatusEngine.shared.setStatus(.done, taskID: taskID, tabID: tabID)
        }
        flushQueue()
    }

    private func handle(request id: CodexRPC.RequestID, method: String, params: JSONValue) {
        switch method {
        case "item/commandExecution/requestApproval":
            enqueue(permission: commandPermission(params), id: id)
        case "item/fileChange/requestApproval":
            enqueue(permission: fileChangePermission(params), id: id)
        default:
            // Every server request must be answered, or the turn stalls.
            client.respondUnsupported(to: id, method: method)
        }
    }

    private func enqueue(permission: PendingPermission, id: CodexRPC.RequestID) {
        permissionRequestIDs[permission.id] = id
        pendingPermissions.append(permission)
        StatusEngine.shared.setStatus(.needsInput, taskID: taskID, tabID: tabID)
    }

    private func commandPermission(_ params: JSONValue) -> PendingPermission {
        let command = params["command"]?.stringValue ?? ""
        return PendingPermission(
            id: params["itemId"]?.stringValue ?? UUID().uuidString,
            toolName: "Shell",
            displayName: "Run command",
            input: ["command": .string(command)],
            description: command,
            decisionReason: params["reason"]?.stringValue,
            toolUseID: params["itemId"]?.stringValue,
            agentID: nil,
            interactive: nil,
            decisions: decisionOptions(in: params, fallback: ["accept", "decline"])
        )
    }

    /// The patch is not in the request — it arrived earlier on the item this
    /// names, which Plume does not track yet.
    private func fileChangePermission(_ params: JSONValue) -> PendingPermission {
        let itemID = params["itemId"]?.stringValue ?? UUID().uuidString
        return PendingPermission(
            id: itemID,
            toolName: "Edit",
            displayName: "Apply file changes",
            input: CodexItemStore.shared.fileChangeInput(tabID: tabID, itemID: itemID),
            description: nil,
            decisionReason: params["reason"]?.stringValue,
            toolUseID: params["itemId"]?.stringValue,
            agentID: nil,
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
        guard let key = permissionRequestIDs.first(where: { $0.value == id })?.key else { return }
        permissionRequestIDs.removeValue(forKey: key)
        pendingPermissions.removeAll { $0.id == key }
    }

    private func reportFailure(_ error: Error) {
        isWorking = false
        lastError = (error as? CodexAppServerClient.Failure).map(String.init(describing:))
            ?? error.localizedDescription
        StatusEngine.shared.setStatus(.error, taskID: taskID, tabID: tabID)
    }

    private func handleExit(status: Int32, message: String?) {
        hasExited = true
        exitStatus = status
        isWorking = false
        if let message { lastError = message }
        StatusEngine.shared.setStatus(status == 0 ? .idle : .error, taskID: taskID, tabID: tabID)
    }
}
