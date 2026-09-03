import Foundation
import os

/// A pending `can_use_tool` request awaiting the user's answer.
struct PendingPermission: Identifiable, Equatable {
    let id: String
    let toolName: String
    let displayName: String
    let input: [String: JSONValue]
    let description: String?
    let decisionReason: String?
    let toolUseID: String?
    /// Set when the call came from a subagent rather than the main thread.
    let agentID: String?
    /// The structured face of an `AskUserQuestion` or `ExitPlanMode`, so the
    /// UI can offer options or a plan instead of raw JSON.
    let interactive: InteractiveToolPayload?

    static func == (lhs: PendingPermission, rhs: PendingPermission) -> Bool { lhs.id == rhs.id }
}

/// One headless `claude` conversation, driving a tab.
///
/// Holds the process, the control-request bookkeeping, and the live turn
/// state the chat view renders. The transcript on disk remains the source of
/// truth for history; this supplies what a file cannot — pending permissions,
/// streaming text, and quota pushed as events.
@MainActor
@Observable
final class HeadlessSession {
    let tabID: UUID
    let taskID: UUID

    private(set) var sessionID: String?
    private(set) var isWorking = false
    private(set) var hasExited = false
    private(set) var exitStatus: Int32?

    /// Requests waiting on the user. Never auto-answered: an unanswered
    /// request stalls its tool call indefinitely, which is the whole reason
    /// the approval UI must exist.
    private(set) var pendingPermissions: [PendingPermission] = []

    /// Text of the turn in flight, assembled from partial-message deltas.
    ///
    /// Kept past the turn's `result` rather than cleared, because the
    /// transcript that replaces it is written on a debounce and would leave a
    /// gap. `ChatStreamHandoff` retires it once the same text is on disk; a
    /// new turn clears it outright.
    private(set) var streamingText = ""
    private(set) var streamingThinking = ""

    private(set) var rateLimit: RateLimitInfo?
    /// `total_cost_usd` is per turn, so a session total accumulates.
    private(set) var sessionCostUSD: Double = 0
    private(set) var contextWindow: Int?
    private(set) var contextUsedTokens: Int?
    private(set) var slashCommands: [SlashCommand] = []
    private(set) var lastError: String?

    /// Set optimistically when the host asks for a change, then corrected
    /// from whatever the stream reports — `init` for `model`/`permissionMode`,
    /// which round-trip through a real control request. There is no
    /// `set_effort` control request (`docs/headless-protocol.md`), so
    /// `effort` is never corrected; it only ever reflects what this host sent.
    private(set) var permissionMode: PermissionMode?
    private(set) var model: AgentModel?
    private(set) var effort: AgentEffort?

    /// Messages typed while a turn is in flight, sent when it finishes.
    private(set) var queuedMessages: [String] = []

    private var process: HeadlessProcess?
    private var nextRequestNumber = 0

    init(tabID: UUID, taskID: UUID) {
        self.tabID = tabID
        self.taskID = taskID
    }

    // MARK: - Lifecycle

    func start(
        workingDirectory: String?,
        permissionMode: PermissionMode?,
        resumeSessionID: String?,
        settingsPath: String?,
        environment: [String: String] = [:]
    ) {
        guard process == nil else { return }
        self.permissionMode = permissionMode
        let arguments = HeadlessCommand.arguments(
            resumeSessionID: resumeSessionID,
            permissionMode: permissionMode,
            settingsPath: settingsPath
        )
        let handler = HeadlessProcess(
            onMessage: { [weak self] message in
                Task { @MainActor in self?.handle(message) }
            },
            onExit: { [weak self] status in
                Task { @MainActor in self?.handleExit(status: status) }
            }
        )
        do {
            try handler.start(
                arguments: arguments,
                workingDirectory: workingDirectory,
                environment: environment
            )
        } catch {
            Log.agent.error("Headless launch failed: \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
            hasExited = true
            return
        }
        process = handler
        // Registers this host as a capable client, and returns the session's
        // slash commands.
        send(StreamJSONEncoder.initialize(requestID: nextRequestID()))
    }

    func stop() {
        process?.terminate()
        process = nil
        hasExited = true
    }

    // MARK: - Sending

    func submit(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !isWorking else {
            queuedMessages.append(trimmed)
            return
        }
        beginTurn()
        send(StreamJSONEncoder.userTurn(text: trimmed))
    }

    /// Removes and returns the queued message at `index`, so a caller can
    /// both dequeue it and recover its text (e.g. to edit it in the
    /// composer). Nil when the index is out of range.
    @discardableResult
    func removeQueuedMessage(at index: Int) -> String? {
        guard queuedMessages.indices.contains(index) else { return nil }
        return queuedMessages.remove(at: index)
    }

    /// Ends the turn in flight but keeps the session alive, unlike a signal.
    func interrupt() {
        guard isWorking else { return }
        send(StreamJSONEncoder.interrupt(requestID: nextRequestID()))
    }

    func setPermissionMode(_ mode: PermissionMode) {
        permissionMode = mode
        send(StreamJSONEncoder.setPermissionMode(mode.token, requestID: nextRequestID()))
    }

    func setModel(_ newModel: AgentModel) {
        model = newModel
        send(StreamJSONEncoder.setModel(newModel.token, requestID: nextRequestID()))
    }

    /// No `set_effort` control request exists, so this rides `submit(text:)`
    /// as an ordinary user turn — the same path a typed `/effort` command
    /// would take — which is why changing effort is visible as a message in
    /// the chat. The value is tracked here regardless, so the composer's
    /// control reflects it immediately rather than waiting on that turn.
    func setEffort(_ newEffort: AgentEffort) {
        effort = newEffort
        submit(text: ModelEffortCommand.setEffort(newEffort))
    }

    func resolve(_ permission: PendingPermission, with decision: PermissionDecision) {
        pendingPermissions.removeAll { $0.id == permission.id }
        send(StreamJSONEncoder.permissionResponse(requestID: permission.id, decision: decision))
    }

    /// Answers an `AskUserQuestion`, keyed by question text to chosen labels.
    func answer(_ permission: PendingPermission, answers: [String: String]) {
        let input = StreamJSONEncoder.answeredQuestionInput(
            original: permission.input,
            answers: answers
        )
        resolve(permission, with: .allow(updatedInput: input))
    }

    // MARK: - Receiving

    /// `internal` rather than `private` so tests can feed it a decoded
    /// message directly, without a real process.
    func handle(_ message: StreamJSONMessage) {
        switch message {
        case .rateLimit(let info):
            rateLimit = info

        case .initialized(let info):
            if !info.sessionID.isEmpty { sessionID = info.sessionID }
            if let reported = info.model, let recognized = AgentModel.recognizing(reported) {
                model = recognized
            }
            if let reported = info.permissionMode, let recognized = PermissionMode.recognizing(reported) {
                permissionMode = recognized
            }

        case .status:
            break

        case .streamEvent(let event):
            // A turn can produce several messages: answering a question or
            // approving a tool resumes the same turn with a fresh one. Each
            // starts the live text over, or the earlier message stays stuck in
            // front of it and never matches what the transcript writes.
            if event.eventType == "message_start" {
                streamingText = ""
                streamingThinking = ""
            }
            if let delta = event.textDelta { streamingText += delta }
            if let delta = event.thinkingDelta { streamingThinking += delta }

        case .assistant, .user:
            // History comes from the transcript file, which the parser already
            // renders. Envelopes only mark that the turn is producing content.
            break

        case .result(let result):
            endTurn(result)

        case .controlRequest(let request):
            handle(request)

        case .controlResponse(let response):
            handle(response)

        case .controlCancel(let requestID):
            // The CLI no longer needs an answer; drop any UI for it.
            pendingPermissions.removeAll { $0.id == requestID }

        case .unknown:
            break
        }
    }

    private func handle(_ request: ControlRequest) {
        guard request.subtype == "can_use_tool" else { return }
        let name = request.toolName ?? "Tool"
        pendingPermissions.append(PendingPermission(
            id: request.requestID,
            toolName: name,
            displayName: request.displayName ?? name,
            input: request.input,
            description: request.description,
            decisionReason: request.decisionReason,
            toolUseID: request.toolUseID,
            agentID: request.agentID,
            interactive: InteractiveToolPayload.decoding(name: name, input: request.input)
        ))
        StatusEngine.shared.setStatus(.needsInput, taskID: taskID, tabID: tabID)
    }

    private func handle(_ response: ControlResponse) {
        // The initialize reply is the only one carrying anything Plume wants.
        let commands = response.payload["commands"]?.arrayValue ?? []
        guard !commands.isEmpty else { return }
        slashCommands = commands.compactMap { value in
            guard let object = value.objectValue, let name = object["name"]?.stringValue else { return nil }
            return SlashCommand(
                name: name,
                description: object["description"]?.stringValue ?? "",
                argumentHint: object["argumentHint"]?.stringValue ?? ""
            )
        }
    }

    private func beginTurn() {
        isWorking = true
        streamingText = ""
        streamingThinking = ""
        lastError = nil
        StatusEngine.shared.setStatus(.working, taskID: taskID, tabID: tabID)
    }

    private func endTurn(_ result: TurnResult) {
        isWorking = false
        // The streamed text is not cleared here — see its declaration.
        if let cost = result.totalCostUSD { sessionCostUSD += cost }
        if let window = result.contextWindow { contextWindow = window }
        if let input = result.inputTokens, let output = result.outputTokens {
            contextUsedTokens = input + output
        }
        if result.isError {
            lastError = result.text ?? "The turn failed."
            StatusEngine.shared.setStatus(.error, taskID: taskID, tabID: tabID)
        } else {
            StatusEngine.shared.setStatus(.done, taskID: taskID, tabID: tabID)
        }
        sendNextQueuedMessage()
    }

    private func sendNextQueuedMessage() {
        guard !queuedMessages.isEmpty else { return }
        let next = queuedMessages.removeFirst()
        beginTurn()
        send(StreamJSONEncoder.userTurn(text: next))
    }

    private func handleExit(status: Int32) {
        hasExited = true
        isWorking = false
        streamingText = ""
        streamingThinking = ""
        exitStatus = status
        process = nil
        // Anything still pending will never be answered now.
        pendingPermissions.removeAll()
        StatusEngine.shared.setStatus(status == 0 ? .idle : .error, taskID: taskID, tabID: tabID)
    }

    private func send(_ line: String?) {
        guard let line else { return }
        process?.send(line: line)
    }

    private func nextRequestID() -> String {
        nextRequestNumber += 1
        return "plume-\(nextRequestNumber)"
    }
}
