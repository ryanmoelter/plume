import Foundation

/// The wire vocabulary of `claude -p --output-format stream-json`.
///
/// `docs/headless-protocol.md` is the reference, verified against Claude Code
/// 2.1.258. Decoding is deliberately forgiving: an unrecognized message keeps
/// its raw payload as `.unknown` rather than failing the stream, because the
/// CLI adds event kinds between releases and a hard failure would strand a
/// live conversation.
enum StreamJSONMessage {
    case rateLimit(RateLimitInfo)
    case initialized(SessionInit)
    case status(String)
    case bridgeState(BridgeState)
    case streamEvent(PartialEvent)
    case assistant(MessageEnvelope)
    case user(MessageEnvelope)
    case result(TurnResult)
    case controlRequest(ControlRequest)
    case controlResponse(ControlResponse)
    case controlCancel(requestID: String)
    case unknown(type: String)
}

struct RateLimitInfo: Equatable, Codable {
    struct Window: Equatable, Codable {
        /// 0–1, not a percentage. The statusline payload this replaces
        /// reported 0–100, so every display scales it here rather than
        /// assuming the old range.
        let utilization: Double
        let resetsAt: Date?
    }

    let fiveHour: Window?
    let sevenDay: Window?
    let isUsingOverage: Bool
}

struct SessionInit: Equatable {
    let sessionID: String
    let cwd: String?
    let model: String?
    let permissionMode: String?
    let tools: [String]
    let slashCommands: [String]
}

/// A slash command the session can run, from the `initialize` handshake reply.
struct SlashCommand: Equatable, Identifiable, Sendable {
    let name: String
    let description: String
    let argumentHint: String
    /// True for a command Plume serves itself rather than one the CLI
    /// reported, so the autocomplete row can mark it.
    var isPlumeProvided: Bool = false

    var id: String { name }
}

/// The Remote Control bridge announcing its own state, on the conversation
/// plane rather than the control plane.
///
/// `state` stays a `String` because the CLI's vocabulary is undocumented and
/// grows between releases; `RemoteControlState` is the one place that
/// interprets it. `epoch` is absent on the first event of a connect and
/// present from the second on.
struct BridgeState: Equatable {
    let state: String
    let detail: String?
    let epoch: Int?
}

struct MessageEnvelope {
    let raw: [String: JSONValue]
    /// Set when the message belongs to a subagent rather than the main thread.
    let parentToolUseID: String?
    let sessionID: String?
}

/// A token-level delta from `--include-partial-messages`.
struct PartialEvent {
    let eventType: String
    let index: Int?
    let textDelta: String?
    let thinkingDelta: String?
    /// The API message id, carried only by `message_start`. The transcript
    /// keys the same message by it, which is what lets the live reply and
    /// the transcript's copy be one message.
    let messageID: String?
}

struct TurnResult {
    let subtype: String
    let isError: Bool
    let text: String?
    /// A running total for the whole conversation, not a per-turn charge —
    /// each `result` replaces the session's tracked cost rather than adding to it.
    let totalCostUSD: Double?
    let contextWindow: Int?
    let inputTokens: Int?
    let cacheReadInputTokens: Int?
    let cacheCreationInputTokens: Int?
    let outputTokens: Int?
    let permissionDenials: Int

    var contextUsedTokens: Int? {
        ContextUsage.total(
            input: inputTokens,
            cacheRead: cacheReadInputTokens,
            cacheCreation: cacheCreationInputTokens,
            output: outputTokens
        )
    }
}

/// Everything occupying the context window after a turn, from the four token
/// counts every usage payload reports.
///
/// Cached input is the bulk of it in any conversation past the first turn — a
/// real turn here reported `input_tokens: 2` against
/// `cache_read_input_tokens: 270017`, so counting only the uncached input
/// under-reports by three orders of magnitude.
///
/// Shared by the stream's `TurnResult` and the transcript's `TranscriptUsage`
/// so a resumed conversation and a live one report the same number.
nonisolated enum ContextUsage {
    static func total(input: Int?, cacheRead: Int?, cacheCreation: Int?, output: Int?) -> Int? {
        let parts = [input, cacheRead, cacheCreation, output]
        guard parts.contains(where: { $0 != nil }) else { return nil }
        return parts.compactMap { $0 }.reduce(0, +)
    }
}

struct ControlRequest {
    let requestID: String
    let subtype: String
    let toolName: String?
    let displayName: String?
    let input: [String: JSONValue]
    let description: String?
    let decisionReason: String?
    let toolUseID: String?
    let agentID: String?
    /// True for tools that reach the host even when an allow rule matches —
    /// `AskUserQuestion` and `ExitPlanMode`. No allowlist can route past one.
    let requiresUserInteraction: Bool
}

struct ControlResponse {
    let requestID: String
    let subtype: String
    let payload: [String: JSONValue]
    /// Set when `subtype` is `error`, where the CLI sends a bare `error`
    /// string beside `request_id` and no `response` object at all.
    let errorMessage: String?

    var isError: Bool { subtype == "error" }
}
