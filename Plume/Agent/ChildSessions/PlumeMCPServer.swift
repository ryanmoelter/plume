import Foundation

/// The tools Plume serves to its headless Claude sessions.
nonisolated enum PlumeMCPTool: String, CaseIterable {
    case startSession = "start_session"
    case sendMessage = "send_message"

    /// The name the model and `can_use_tool` know the tool by.
    var qualifiedName: String { "mcp__\(PlumeMCPServer.serverName)__\(rawValue)" }
}

/// Plume's own MCP server, which a headless Claude session reaches over the
/// control plane as `mcp_message` requests. JSON-RPC in, JSON-RPC out; a tool
/// call goes to `callTool`, whose answer becomes the reply.
///
/// `docs/headless-protocol.md` has the wire shapes and `docs/child-sessions.md`
/// the tools.
@MainActor
final class PlumeMCPServer {
    nonisolated static let serverName = "plume"
    nonisolated static let protocolVersion = "2025-06-18"

    let name = PlumeMCPServer.serverName

    enum Role: Equatable {
        case parent
        /// A session another one started, which may message its parent but
        /// start no sessions of its own.
        case child(parentID: String)
    }

    struct ToolCall: Equatable {
        let tool: PlumeMCPTool
        let arguments: [String: JSONValue]
        let toolUseID: String?
    }

    struct ToolResult: Equatable {
        let text: String
        let isError: Bool

        static func success(_ text: String) -> ToolResult { ToolResult(text: text, isError: false) }
        static func failure(_ text: String) -> ToolResult { ToolResult(text: text, isError: true) }
    }

    private let role: () -> Role
    private let callTool: (ToolCall) async -> ToolResult

    init(role: @escaping () -> Role, callTool: @escaping (ToolCall) async -> ToolResult) {
        self.role = role
        self.callTool = callTool
    }

    func tools(for role: Role) -> [PlumeMCPTool] {
        switch role {
        case .parent: PlumeMCPTool.allCases
        case .child: [.sendMessage]
        }
    }

    /// Plume's own tools, which `decision` answers rather than the user.
    func isAutoAllowed(toolName: String) -> Bool {
        PlumeMCPTool.allCases.contains { $0.qualifiedName == toolName }
    }

    func decision(toolName: String, input: [String: JSONValue], permissionMode: PermissionMode?) -> PermissionDecision? {
        guard isAutoAllowed(toolName: toolName) else { return nil }
        return Self.decision(toolName: toolName, input: input, permissionMode: permissionMode)
    }

    /// How to answer `can_use_tool` for one of Plume's tools, or nil to ask
    /// the user as for any other tool. The CLI asks even in plan mode, where
    /// starting a session is refused. In manual mode, or a mode Plume does
    /// not recognize, a call that starts a session now asks like any other
    /// action; everything else acts only inside Plume and is allowed.
    nonisolated static func decision(
        toolName: String,
        input: [String: JSONValue],
        permissionMode: PermissionMode?
    ) -> PermissionDecision? {
        if toolName == PlumeMCPTool.startSession.qualifiedName {
            if permissionMode == .plan {
                return .deny(message: ChildSessionError.parentInPlanMode.message)
            }
            if permissionMode == .manual || permissionMode == nil, StartSessionRequest.startsNow(input) {
                return nil
            }
        }
        return .allow(updatedInput: input)
    }

    /// The reply to `message`, or nil for a notification, which takes none.
    func handle(_ message: JSONValue) async -> JSONValue? {
        guard let object = message.objectValue, let method = object["method"]?.stringValue else {
            return Self.error(id: message.objectValue?["id"] ?? .null, code: -32600, message: "Invalid request")
        }
        guard let id = object["id"] else { return nil }
        let params = object["params"]?.objectValue ?? [:]
        switch method {
        case "initialize":
            return Self.result(id: id, initializeResult(params: params))
        case "tools/list":
            return Self.result(id: id, .object(["tools": .array(tools(for: role()).map(Self.definition))]))
        case "tools/call":
            return await callResult(id: id, params: params)
        case "ping":
            return Self.result(id: id, .object([:]))
        default:
            return Self.error(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    /// An `mcp_message` for a server this session does not serve.
    nonisolated static func unknownServerReply(to message: JSONValue?, named server: String?) -> JSONValue? {
        guard let id = message?.objectValue?["id"] else { return nil }
        return error(id: id, code: -32601, message: "No MCP server named \(server ?? "(none)")")
    }

    private func initializeResult(params: [String: JSONValue]) -> JSONValue {
        .object([
            "protocolVersion": params["protocolVersion"] ?? .string(Self.protocolVersion),
            "capabilities": .object(["tools": .object([:])]),
            "serverInfo": .object(["name": .string(name), "version": .string("1")]),
            "instructions": .string(ChildSessionFormats.instructions(for: role()))
        ])
    }

    private func callResult(id: JSONValue, params: [String: JSONValue]) async -> JSONValue {
        let name = params["name"]?.stringValue ?? ""
        guard let tool = PlumeMCPTool(rawValue: name) else {
            return Self.error(id: id, code: -32602, message: "Unknown tool: \(name)")
        }
        let result: ToolResult
        if tools(for: role()).contains(tool) {
            result = await callTool(ToolCall(
                tool: tool,
                arguments: params["arguments"]?.objectValue ?? [:],
                toolUseID: params["_meta"]?.objectValue?["claudecode/toolUseId"]?.stringValue
            ))
        } else {
            result = .failure("\(tool.rawValue) is not available here: a session another session started cannot start sessions of its own.")
        }
        var payload: [String: JSONValue] = [
            "content": .array([.object(["type": .string("text"), "text": .string(result.text)])])
        ]
        if result.isError { payload["isError"] = .bool(true) }
        return Self.result(id: id, .object(payload))
    }

    private static func result(id: JSONValue, _ result: JSONValue) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": id, "result": result])
    }

    nonisolated private static func error(id: JSONValue, code: Int, message: String) -> JSONValue {
        .object([
            "jsonrpc": .string("2.0"),
            "id": id,
            "error": .object(["code": .number(Double(code)), "message": .string(message)])
        ])
    }

    private static func definition(_ tool: PlumeMCPTool) -> JSONValue {
        .object([
            "name": .string(tool.rawValue),
            "description": .string(ChildSessionFormats.description(of: tool)),
            "inputSchema": ChildSessionFormats.inputSchema(of: tool)
        ])
    }
}
