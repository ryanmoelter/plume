import Foundation

/// Reads a transcript for the Linear issues an agent touched through an MCP
/// server.
nonisolated enum LinearActivityScanner {
    static func scan(_ messages: [ChatMessage], subagent: LinearSubagentRef?) -> [LinearEvidence] {
        var evidence: [LinearEvidence] = []
        for message in messages {
            for block in message.blocks {
                guard case .toolCall(let call) = block, let tool = linearTool(call.name) else { continue }
                evidence += scan(call, tool: tool, subagent: subagent)
            }
        }
        return evidence
    }

    private static func linearTool(_ name: String) -> String? {
        guard name.hasPrefix("mcp__") else { return nil }
        let parts = name.components(separatedBy: "__")
        guard parts.count >= 3, parts[1].localizedCaseInsensitiveContains("linear") else { return nil }
        return parts[2...].joined(separator: "__")
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
                identifiers.append(id)
            }
        }
        if issue, let result = call.result, let id = resultIdentifier(result), !identifiers.contains(id) {
            identifiers.append(id)
        }

        let state = (tool == "save_issue" || tool == "update_issue")
            ? (input["state"] as? String) ?? (input["stateId"] as? String)
            : nil
        return identifiers.map {
            LinearEvidence(identifier: $0, tool: tool, requestedState: state, subagent: subagent)
        }
    }

    private static func resultIdentifier(_ result: String) -> String? {
        guard let object = parseObject(result) else { return nil }
        for key in ["identifier", "id"] {
            if let value = object[key] as? String, let id = LinearIdentifier.normalize(value) { return id }
        }
        return nil
    }

    private static func parseObject(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
