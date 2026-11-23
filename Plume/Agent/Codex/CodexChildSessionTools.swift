import Foundation

@MainActor
struct CodexChildSessionTools {
    let role: PlumeMCPServer.Role
    let run: (PlumeMCPServer.ToolCall, Bool) async -> PlumeMCPServer.ToolResult

    var definitions: [JSONValue] {
        tools.map { tool in
            var description = ChildSessionFormats.description(of: tool)
            if tool == .startSession {
                description += " A Codex parent starts fresh sessions only. Use a native subagent for a quick lookup that must finish before you continue. Reports arrive as later turns; do not poll."
            }
            return .object([
                "type": .string("function"),
                "name": .string(tool.codexName),
                "description": .string(description),
                "inputSchema": ChildSessionFormats.inputSchema(of: tool)
            ])
        }
    }

    func call(_ params: JSONValue, toolUseID: String?) -> PlumeMCPServer.ToolCall? {
        guard params["namespace"] == nil || params["namespace"] == .null,
              let name = params["tool"]?.stringValue,
              let tool = tools.first(where: { $0.codexName == name }),
              let arguments = params["arguments"]?.objectValue
        else { return nil }
        return .init(tool: tool, arguments: arguments, toolUseID: toolUseID)
    }

    private var tools: [PlumeMCPTool] {
        switch role {
        case .parent: PlumeMCPTool.allCases
        case .child: [.sendMessage]
        }
    }
}

nonisolated extension PlumeMCPTool {
    var codexName: String { "plume_" + rawValue }

    func matches(_ name: String) -> Bool { name == qualifiedName || name == codexName }
}
