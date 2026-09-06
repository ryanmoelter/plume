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
    /// `total_cost_usd` is a running total for the whole conversation, so
    /// each `result` replaces the prior value rather than adding to it —
    /// that also keeps the figure correct across a `--resume`.
    private(set) var sessionCostUSD: Double = 0
    private(set) var contextWindow: Int?
    private(set) var contextUsedTokens: Int?
    /// `model`'s assumed window, so the meter has a denominator as soon as a
    /// model is picked — before `contextWindow` has anything reported.
    var nominalContextWindow: Int? { model?.nominalContextWindow }
    private(set) var slashCommands: [SlashCommand] = []
    private(set) var lastError: String?

    /// Whether this conversation is published to claude.ai/code. In memory
    /// only — the bridge belongs to the process, not to the tab.
    private(set) var remoteControl: RemoteControlState = .disconnected

    /// Set optimistically when the host asks for a change, then corrected
    /// from whatever the stream reports — `init` for `model`/`permissionMode`,
    /// which round-trip through a real control request. There is no
    /// `set_effort` control request (`docs/headless-protocol.md`), so
    /// `effort` is never corrected; it only ever reflects what this host sent.
    private(set) var permissionMode: PermissionMode?
    private(set) var model: AgentModel?
    private(set) var effort: AgentEffort?

    /// False while `model`/`permissionMode` are still Plume's own guess —
    /// seeded from the tab, or asked for at launch — so the UI can show them
    /// as unconfirmed until `init` reports what the conversation really has.
    private(set) var hasReportedModeAndModel = false

    /// Messages typed while a turn is in flight, sent when it finishes.
    private(set) var queuedMessages: [String] = []

    private var process: HeadlessProcess?
    private var pendingControlRequests: [String: PendingControlRequest] = [:]
    private var nextRequestNumber = 0

    /// `initialEffort` seeds the displayed value from the tab's last-known
    /// effort, so a resumed session's control shows it immediately instead of
    /// the "Effort" placeholder. It only sets the property directly — never
    /// through `setEffort(_:)`, which submits a real turn to the CLI.
    init(tabID: UUID, taskID: UUID, initialEffort: AgentEffort? = nil) {
        self.tabID = tabID
        self.taskID = taskID
        self.effort = initialEffort
    }

    #if DEBUG
    /// Feeds the live-text path without a process, so `SmokeHarness` can
    /// stream into a chat rendered from a transcript on disk.
    func debugStream(text delta: String, restart: Bool = false) {
        if restart { streamingText = "" }
        streamingText += delta
    }
    #endif

    // MARK: - Lifecycle

    func start(
        workingDirectory: String?,
        permissionMode: PermissionMode?,
        resumeSessionID: String?,
        settingsPath: String?,
        model: AgentModel? = nil,
        isModelExplicitlyChosen: Bool = true,
        environment: [String: String] = [:]
    ) {
        guard process == nil else { return }
        self.permissionMode = permissionMode
        if let model { self.model = model }
        let arguments = HeadlessCommand.arguments(
            resumeSessionID: resumeSessionID,
            permissionMode: permissionMode,
            settingsPath: settingsPath,
            model: model,
            isModelExplicitlyChosen: isModelExplicitlyChosen
        )
        let handler = HeadlessProcess(
            onMessage: { [weak self] message in
                Task { @MainActor in self?.handle(message) }
            },
            onExit: { [weak self] status, errorLine in
                Task { @MainActor in self?.handleExit(status: status, errorLine: errorLine) }
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
        let requestID = nextRequestID()
        pendingControlRequests[requestID] = .initialize
        send(StreamJSONEncoder.initialize(requestID: requestID))
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
        guard send(StreamJSONEncoder.userTurn(text: trimmed)) else {
            // The process died before the text reached it. Keeping the
            // message queued means a restart can still deliver it, instead of
            // losing what the user typed to a silent drop.
            queuedMessages.append(trimmed)
            isWorking = false
            if lastError == nil { lastError = "claude is not running; the message was not sent" }
            return
        }
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

    /// Publishes this conversation to claude.ai/code, or tears that down.
    ///
    /// `name` labels the session in the web UI. Set optimistically, the same
    /// way `model` and `permissionMode` are, and corrected by the reply — a
    /// disable is acknowledged with a bare success, so nothing corrects it
    /// and the optimistic value stands.
    func setRemoteControl(enabled: Bool, name: String? = nil) {
        remoteControl = enabled ? .connecting : .disconnected
        let requestID = nextRequestID()
        pendingControlRequests[requestID] = .remoteControl(enabled: enabled)
        guard send(StreamJSONEncoder.remoteControl(
            enabled: enabled,
            name: name,
            requestID: requestID
        )) else {
            pendingControlRequests[requestID] = nil
            remoteControl = enabled ? .failed("claude is not running.") : .disconnected
            return
        }
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

    /// Approves an `ExitPlanMode` call. Allowing the call only answers the
    /// tool; the CLI has no field on that response for changing mode
    /// (`docs/headless-protocol.md`), so leaving plan mode takes the separate
    /// `set_permission_mode` request the TUI's Shift+Tab sends on this same
    /// action. Without it the session stays in `plan` and never starts work.
    func approvePlan(_ permission: PendingPermission) {
        resolve(permission, with: .allow(updatedInput: permission.input))
        setPermissionMode(.auto)
    }

    /// Approves the plan and sends `feedback` as an ordinary user turn.
    ///
    /// The note cannot ride the permission response: `ExitPlanMode` declares
    /// no input fields — it reads the plan from `planFilePath` — so an extra
    /// key on `updatedInput` is dropped without a diagnostic, and there is no
    /// allow-with-message on the wire (`docs/headless-protocol.md`). A user
    /// turn is the only path that reliably reaches the model. `submit(text:)`
    /// queues it while the approved turn runs and flushes it when that turn
    /// ends, which is when the note is wanted: it steers the next plan rather
    /// than interrupting the one being approved.
    func approvePlan(_ permission: PendingPermission, feedback: String) {
        approvePlan(permission)
        submit(text: feedback)
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
            hasReportedModeAndModel = true
            if let reported = info.model, let recognized = AgentModel.recognizing(reported) {
                model = recognized
            }
            if let reported = info.permissionMode, let recognized = PermissionMode.recognizing(reported) {
                permissionMode = recognized
            }

        case .status:
            break

        case .bridgeState(let bridge):
            remoteControl = remoteControl.applying(bridge)

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
        // Plume sends no work secret, so the bridge should never ask for a
        // fresher one. If it does, a bare success says "nothing to offer" —
        // dropping the request would leave the CLI waiting on its timeout.
        if request.subtype == "remote_control_work_secret" {
            send(StreamJSONEncoder.controlSuccess(requestID: request.requestID))
            return
        }
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
        guard let pending = pendingControlRequests.removeValue(forKey: response.requestID) else { return }
        switch pending {
        case .initialize:
            applyReportedCommands(in: response)
        case .remoteControl(let enabled):
            remoteControl = RemoteControlState.applying(
                response: response,
                enabled: enabled,
                current: remoteControl
            )
        }
    }

    private func applyReportedCommands(in response: ControlResponse) {
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
        if let cost = result.totalCostUSD { sessionCostUSD = cost }
        if let window = result.contextWindow { contextWindow = window }
        if let used = result.contextUsedTokens { contextUsedTokens = used }
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
        guard send(StreamJSONEncoder.userTurn(text: next)) else {
            queuedMessages.insert(next, at: 0)
            isWorking = false
            return
        }
    }

    private func handleExit(status: Int32, errorLine: String?) {
        hasExited = true
        isWorking = false
        streamingText = ""
        streamingThinking = ""
        exitStatus = status
        process = nil
        if status != 0, lastError == nil {
            lastError = errorLine ?? "claude exited with status \(status)"
        }
        // Anything still pending will never be answered now.
        pendingPermissions.removeAll()
        pendingControlRequests.removeAll()
        // The bridge cannot outlive the process that served it.
        remoteControl = .disconnected
        StatusEngine.shared.setStatus(status == 0 ? .idle : .error, taskID: taskID, tabID: tabID)
    }

    @discardableResult
    private func send(_ line: String?) -> Bool {
        guard let line, let process else { return false }
        return process.send(line: line)
    }

    private func nextRequestID() -> String {
        nextRequestNumber += 1
        return "plume-\(nextRequestNumber)"
    }

    /// A request whose reply carries something Plume acts on, remembered by
    /// id until it arrives. Replies to everything else are ignored.
    private enum PendingControlRequest {
        case initialize
        case remoteControl(enabled: Bool)
    }
}
