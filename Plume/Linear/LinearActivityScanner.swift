import Foundation

/// Reads a transcript for the Linear issues an agent touched through an MCP
/// server.
nonisolated enum LinearActivityScanner {
    static func scan(_ messages: [ChatMessage], subagent: LinearSubagentRef?) -> [LinearEvidence] {
        var evidence: [LinearEvidence] = []
        for message in messages {
            for block in message.blocks {
                guard case .toolCall(let call) = block else { continue }
                evidence += scan(call, subagent: subagent)
            }
        }
        return evidence
    }

    static func scan(_ call: ToolCall, subagent: LinearSubagentRef?) -> [LinearEvidence] {
        guard let tool = linearTool(call.name) else { return [] }
        return scan(call, tool: tool, subagent: subagent)
    }

    static func toolName(server: String, tool: String) -> String? {
        if server == "codex_apps" {
            for prefix in ["linear.", "linear_"] where tool.hasPrefix(prefix) {
                return String(tool.dropFirst(prefix.count))
            }
            return nil
        }
        guard server.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).contains("linear") else { return nil }
        return tool
    }

    private static func linearTool(_ name: String) -> String? {
        guard name.hasPrefix("mcp__") else { return nil }
        let parts = name.components(separatedBy: "__")
        guard parts.count >= 3 else { return nil }
        return toolName(server: parts[1], tool: parts[2...].joined(separator: "__"))
    }

    /// Tools whose input names one issue. List and search tools are excluded
    /// so one call cannot link a whole page of issues.
    private static func isIssueTool(_ tool: String) -> Bool {
        tool.hasSuffix("_issue")
    }

    private static func isCommentTool(_ tool: String) -> Bool {
        tool.hasSuffix("_comment") || tool == "list_comments"
    }

    private static func scan(_ call: ToolCall, tool: String, subagent: LinearSubagentRef?) -> [LinearEvidence] {
        let issue = isIssueTool(tool)
        guard issue || isCommentTool(tool), case .json(let text) = call.input,
              let input = parseObject(text)
        else { return [] }

        var identifiers: [String] = []
        for key in ["id", "issueId", "identifier"] {
            if let value = input[key] as? String, let id = LinearIdentifier.normalize(value) {
                if !identifiers.contains(id) { identifiers.append(id) }
            }
        }
        if issue, !call.didFail, let result = call.result, let id = resultIdentifier(result), !identifiers.contains(id) {
            identifiers.append(id)
        }

        let state = (tool == "save_issue" || tool == "update_issue")
            ? (input["state"] as? String) ?? (input["stateId"] as? String)
            : nil
        let outcome: LinearCallOutcome = call.result == nil ? .pending : call.didFail ? .failed : .succeeded
        return identifiers.map {
            LinearEvidence(identifier: $0, tool: tool, requestedState: state, subagent: subagent, outcome: outcome)
        }
    }

    private static func resultIdentifier(_ result: String) -> String? {
        guard let object = parseObject(result) else { return nil }
        return identifier(in: object)
    }

    private static func identifier(in object: [String: Any]) -> String? {
        for key in ["identifier", "id"] {
            if let value = object[key] as? String, let id = LinearIdentifier.normalize(value) { return id }
        }
        if let structured = object["structuredContent"] as? [String: Any], let id = identifier(in: structured) { return id }
        for content in object["content"] as? [[String: Any]] ?? [] {
            guard content["type"] as? String == "text", let text = content["text"] as? String,
                  let result = parseObject(text), let id = identifier(in: result) else { continue }
            return id
        }
        return nil
    }

    private static func parseObject(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
