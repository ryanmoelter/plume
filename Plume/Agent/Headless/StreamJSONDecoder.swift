import Foundation

/// Turns one NDJSON line from `claude -p` into a `StreamJSONMessage`.
///
/// Pure and synchronous so the wire format can be tested without a process.
enum StreamJSONDecoder {
    static func decode(line: String) -> StreamJSONMessage? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
        guard let root = try? JSONDecoder().decode([String: JSONValue].self, from: data) else { return nil }
        return decode(root: root)
    }

    static func decode(root: [String: JSONValue]) -> StreamJSONMessage? {
        guard let type = root["type"]?.stringValue else { return nil }
        switch type {
        case "rate_limit_event":
            return .rateLimit(rateLimit(from: root["rate_limit_info"]?.objectValue ?? [:]))
        case "system":
            switch root["subtype"]?.stringValue {
            case "init": return .initialized(sessionInit(from: root))
            case "status": return .status(root["status"]?.stringValue ?? "")
            default: return .unknown(type: "system")
            }
        case "stream_event":
            return .streamEvent(partial(from: root["event"]?.objectValue ?? [:]))
        case "assistant":
            return .assistant(envelope(from: root))
        case "user":
            return .user(envelope(from: root))
        case "result":
            return .result(turnResult(from: root))
        case "control_request":
            guard let id = root["request_id"]?.stringValue else { return nil }
            return .controlRequest(controlRequest(id: id, body: root["request"]?.objectValue ?? [:]))
        case "control_response":
            let body = root["response"]?.objectValue ?? [:]
            guard let id = body["request_id"]?.stringValue else { return nil }
            return .controlResponse(ControlResponse(
                requestID: id,
                subtype: body["subtype"]?.stringValue ?? "success",
                payload: body["response"]?.objectValue ?? [:]
            ))
        case "control_cancel_request":
            guard let id = root["request_id"]?.stringValue else { return nil }
            return .controlCancel(requestID: id)
        default:
            return .unknown(type: type)
        }
    }

    private static func rateLimit(from info: [String: JSONValue]) -> RateLimitInfo {
        let windows = info["unifiedWindows"]?.objectValue ?? [:]
        return RateLimitInfo(
            fiveHour: window(from: windows["five_hour"]?.objectValue),
            sevenDay: window(from: windows["seven_day"]?.objectValue),
            isUsingOverage: info["isUsingOverage"]?.boolValue ?? false
        )
    }

    private static func window(from object: [String: JSONValue]?) -> RateLimitInfo.Window? {
        guard let object, let utilization = object["utilization"]?.doubleValue else { return nil }
        let resets = object["resetsAt"]?.doubleValue
        return RateLimitInfo.Window(
            utilization: utilization,
            resetsAt: resets.map { Date(timeIntervalSince1970: $0) }
        )
    }

    private static func sessionInit(from root: [String: JSONValue]) -> SessionInit {
        SessionInit(
            sessionID: root["session_id"]?.stringValue ?? "",
            cwd: root["cwd"]?.stringValue,
            model: root["model"]?.stringValue,
            permissionMode: root["permissionMode"]?.stringValue,
            tools: (root["tools"]?.arrayValue ?? []).compactMap(\.stringValue),
            slashCommands: (root["slash_commands"]?.arrayValue ?? []).compactMap(\.stringValue)
        )
    }

    private static func partial(from event: [String: JSONValue]) -> PartialEvent {
        let delta = event["delta"]?.objectValue ?? [:]
        return PartialEvent(
            eventType: event["type"]?.stringValue ?? "",
            index: event["index"]?.doubleValue.map(Int.init),
            textDelta: delta["text"]?.stringValue,
            thinkingDelta: delta["thinking"]?.stringValue
        )
    }

    private static func envelope(from root: [String: JSONValue]) -> MessageEnvelope {
        MessageEnvelope(
            raw: root["message"]?.objectValue ?? [:],
            parentToolUseID: root["parent_tool_use_id"]?.stringValue,
            sessionID: root["session_id"]?.stringValue
        )
    }

    private static func turnResult(from root: [String: JSONValue]) -> TurnResult {
        let usage = root["usage"]?.objectValue ?? [:]
        return TurnResult(
            subtype: root["subtype"]?.stringValue ?? "",
            isError: root["is_error"]?.boolValue ?? false,
            text: root["result"]?.stringValue,
            totalCostUSD: root["total_cost_usd"]?.doubleValue,
            contextWindow: largestContextWindow(in: root["modelUsage"]?.objectValue ?? [:]),
            inputTokens: usage["input_tokens"]?.doubleValue.map(Int.init),
            outputTokens: usage["output_tokens"]?.doubleValue.map(Int.init),
            permissionDenials: root["permission_denials"]?.arrayValue?.count ?? 0
        )
    }

    /// `modelUsage` reports every model the turn touched, subagents included.
    /// The main thread's model is the one with the largest window.
    private static func largestContextWindow(in modelUsage: [String: JSONValue]) -> Int? {
        modelUsage.values
            .compactMap { $0.objectValue?["contextWindow"]?.doubleValue }
            .max()
            .map(Int.init)
    }

    private static func controlRequest(id: String, body: [String: JSONValue]) -> ControlRequest {
        ControlRequest(
            requestID: id,
            subtype: body["subtype"]?.stringValue ?? "",
            toolName: body["tool_name"]?.stringValue,
            displayName: body["display_name"]?.stringValue,
            input: body["input"]?.objectValue ?? [:],
            description: body["description"]?.stringValue,
            decisionReason: body["decision_reason"]?.stringValue,
            toolUseID: body["tool_use_id"]?.stringValue,
            agentID: body["agent_id"]?.stringValue,
            requiresUserInteraction: body["requires_user_interaction"]?.boolValue ?? false
        )
    }
}
