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
    case streamEvent(PartialEvent)
    case assistant(MessageEnvelope)
    case user(MessageEnvelope)
    case result(TurnResult)
    case controlRequest(ControlRequest)
    case controlResponse(ControlResponse)
    case controlCancel(requestID: String)
    case unknown(type: String)
}

struct RateLimitInfo: Equatable {
    struct Window: Equatable {
        /// 0–1, not a percentage. The statusline payload this replaces
        /// reported 0–100, and the display thresholds expect that.
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

    var id: String { name }
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
}

struct TurnResult {
    let subtype: String
    let isError: Bool
    let text: String?
    /// Per turn, so a session total accumulates rather than replaces.
    let totalCostUSD: Double?
    let contextWindow: Int?
    let inputTokens: Int?
    let cacheReadInputTokens: Int?
    let cacheCreationInputTokens: Int?
    let outputTokens: Int?
    let permissionDenials: Int

    /// Everything occupying the context window after this turn.
    ///
    /// Cached input is the bulk of it in any conversation past the first
    /// turn — a real turn here reported `input_tokens: 2` against
    /// `cache_read_input_tokens: 270017`, so counting only the uncached
    /// input under-reports by three orders of magnitude.
    var contextUsedTokens: Int? {
        let parts = [inputTokens, cacheReadInputTokens, cacheCreationInputTokens, outputTokens]
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
}
