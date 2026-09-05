import Foundation

/// One agent conversation, however Plume happens to be talking to it.
///
/// The chat UI renders against this rather than a concrete session, so a tab
/// running Claude Code and a tab running Codex share every view. Each CLI
/// speaks its own protocol behind its own implementation; nothing here
/// describes a wire format.
///
/// Launching is deliberately absent: the arguments differ per CLI, so
/// `AgentLauncher` starts a session through its concrete type and only the
/// running conversation is shared.
@MainActor
protocol AgentSession: AnyObject, Observable {
    var tabID: UUID { get }
    var taskID: UUID { get }

    /// The CLI's own identifier for the conversation, persisted to the tab so
    /// a relaunch can resume it.
    var sessionID: String? { get }
    var isWorking: Bool { get }
    var hasExited: Bool { get }
    var exitStatus: Int32? { get }

    /// Requests waiting on the user. Never auto-answered: an unanswered
    /// request stalls its tool call indefinitely, which is the whole reason
    /// the approval UI must exist.
    var pendingPermissions: [PendingPermission] { get }

    var streamingText: String { get }
    var streamingThinking: String { get }

    var rateLimit: RateLimitInfo? { get }
    /// Nil where the CLI reports usage in tokens only, which hides the cost
    /// readout rather than showing a zero.
    var sessionCostUSD: Double? { get }
    var contextWindow: Int? { get }
    var contextUsedTokens: Int? { get }
    var slashCommands: [SlashCommand] { get }
    var lastError: String? { get }

    var permissionMode: PermissionMode? { get }
    var model: AgentModel? { get }
    var effort: AgentEffort? { get }
    var hasReportedModeAndModel: Bool { get }

    var queuedMessages: [String] { get }

    /// Whether the CLI can propose a plan for approval. False hides the plan
    /// dock outright — a CLI without the concept never produces one, and an
    /// approval control that cannot fire reads as broken.
    var supportsPlanApproval: Bool { get }

    func stop()
    func submit(text: String)
    @discardableResult func removeQueuedMessage(at index: Int) -> String?
    func interrupt()
    func setPermissionMode(_ mode: PermissionMode)
    func setModel(_ newModel: AgentModel)
    func setEffort(_ newEffort: AgentEffort)
    func resolve(_ permission: PendingPermission, with decision: PermissionDecision)
    func approvePlan(_ permission: PendingPermission)
    func approvePlan(_ permission: PendingPermission, feedback: String)
    func answer(_ permission: PendingPermission, answers: [String: String])
}
