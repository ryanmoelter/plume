import Foundation
import Testing
@testable import Plume

/// Plume's MCP server answers the JSON-RPC a headless Claude session sends
/// over `mcp_message`: the handshake, the tool list for its role, tool calls
/// routed to the coordinator, and errors. A notification gets no reply.
/// Message shapes come from probing `claude -p` 2.1.321.
@MainActor
struct PlumeMCPServerTests {
    private final class Calls {
        var received: [PlumeMCPServer.ToolCall] = []
    }

    private func makeServer(
        role: PlumeMCPServer.Role = .parent,
        result: PlumeMCPServer.ToolResult = .success("done")
    ) -> (PlumeMCPServer, Calls) {
        let calls = Calls()
        let server = PlumeMCPServer(role: { role }) { call in
            calls.received.append(call)
            return result
        }
        return (server, calls)
    }

    private func request(_ id: Int, _ method: String, _ params: [String: JSONValue] = [:]) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": .number(Double(id)), "method": .string(method), "params": .object(params)])
    }

    private func toolNames(_ reply: JSONValue?) -> [String] {
        reply?["result"]?["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? []
    }

    @Test func initializeEchoesTheVersionAndCarriesInstructions() async throws {
        let (server, _) = makeServer()
        let reply = try #require(await server.handle(request(0, "initialize", [
            "protocolVersion": .string("2025-03-26"),
            "capabilities": .object([:]),
            "clientInfo": .object(["name": .string("claude-code")])
        ])))

        #expect(reply["id"] == .number(0))
        let result = try #require(reply["result"])
        #expect(result["protocolVersion"]?.stringValue == "2025-03-26")
        #expect(result["capabilities"]?["tools"]?.objectValue == [:])
        #expect(result["serverInfo"]?["name"]?.stringValue == "plume")
        let instructions = try #require(result["instructions"]?.stringValue)
        #expect(instructions.contains("mcp__plume__start_session"))
        #expect(instructions.contains("mcp__plume__send_message"))
    }

    @Test func aParentListsBothTools() async {
        let (server, _) = makeServer()
        let reply = await server.handle(request(1, "tools/list"))
        #expect(toolNames(reply) == ["start_session", "send_message"])
        let schema = reply?["result"]?["tools"]?.arrayValue?.first?["inputSchema"]
        #expect(schema?["required"]?.arrayValue == [.string("title"), .string("prompt"), .string("initiation")])
    }

    @Test func aChildListsOnlySendMessageAndLearnsItsParent() async {
        let (server, _) = makeServer(role: .child(parentID: "PARENT-ID"))
        #expect(toolNames(await server.handle(request(1, "tools/list"))) == ["send_message"])
        let instructions = await server.handle(request(0, "initialize"))?["result"]?["instructions"]?.stringValue
        #expect(instructions?.contains("PARENT-ID") == true)
        #expect(instructions?.contains("mcp__plume__send_message") == true)
    }

    @Test func aCallReachesTheHandlerWithItsArgumentsAndToolUseID() async throws {
        let (server, calls) = makeServer(result: .success("Started"))
        let reply = await server.handle(request(3, "tools/call", [
            "name": .string("send_message"),
            "arguments": .object(["to": .string("abc"), "message": .string("hi")]),
            "_meta": .object(["claudecode/toolUseId": .string("toolu_1")])
        ]))

        let call = try #require(calls.received.first)
        #expect(call.tool == .sendMessage)
        #expect(call.arguments["to"] == .string("abc"))
        #expect(call.toolUseID == "toolu_1")
        #expect(reply?["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue == "Started")
        #expect(reply?["result"]?["isError"] == nil)
    }

    @Test func aFailedCallIsAToolErrorNotAProtocolError() async {
        let (server, _) = makeServer(result: .failure("nope"))
        let reply = await server.handle(request(4, "tools/call", ["name": .string("start_session")]))
        #expect(reply?["error"] == nil)
        #expect(reply?["result"]?["isError"] == .bool(true))
        #expect(reply?["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue == "nope")
    }

    @Test func aChildCannotStartSessions() async {
        let (server, calls) = makeServer(role: .child(parentID: "p"))
        let reply = await server.handle(request(5, "tools/call", ["name": .string("start_session")]))
        #expect(calls.received.isEmpty)
        #expect(reply?["result"]?["isError"] == .bool(true))
    }

    @Test func anUnknownToolOrMethodIsAProtocolError() async {
        let (server, _) = makeServer()
        #expect(await server.handle(request(6, "tools/call", ["name": .string("nope")]))?["error"]?["code"] == .number(-32602))
        #expect(await server.handle(request(7, "resources/list"))?["error"]?["code"] == .number(-32601))
        #expect(await server.handle(.string("garbage"))?["error"]?["code"] == .number(-32600))
    }

    @Test func aNotificationGetsNoReply() async {
        let (server, _) = makeServer()
        let notification: JSONValue = .object(["jsonrpc": .string("2.0"), "method": .string("notifications/initialized")])
        #expect(await server.handle(notification) == nil)
    }

    @Test func onlyPlumesOwnToolsAreAutoAllowed() {
        let (server, _) = makeServer()
        #expect(server.isAutoAllowed(toolName: "mcp__plume__start_session"))
        #expect(server.isAutoAllowed(toolName: "mcp__plume__send_message"))
        #expect(!server.isAutoAllowed(toolName: "mcp__other__start_session"))
        #expect(!server.isAutoAllowed(toolName: "Bash"))
    }

    @Test(arguments: [PermissionMode.manual, nil])
    func aStartAsksInManualMode(mode: PermissionMode?) {
        let input: [String: JSONValue] = ["title": .string("Fix"), "prompt": .string("Go"), "initiation": .string("user_asked")]
        #expect(PlumeMCPServer.decision(toolName: "mcp__plume__start_session", input: input, permissionMode: mode) == nil)
    }

    @Test(arguments: [PermissionMode.auto, .acceptEdits, .bypassPermissions])
    func aStartIsAllowedInMorePermissiveModes(mode: PermissionMode) {
        let input: [String: JSONValue] = ["initiation": .string("user_asked")]
        #expect(PlumeMCPServer.decision(toolName: "mcp__plume__start_session", input: input, permissionMode: mode)
            == .allow(updatedInput: input))
    }

    @Test func aCallThatStartsNothingIsAllowedInManualMode() {
        for initiation in ["own_initiative", "offer"] {
            let input: [String: JSONValue] = ["initiation": .string(initiation)]
            #expect(PlumeMCPServer.decision(toolName: "mcp__plume__start_session", input: input, permissionMode: .manual)
                == .allow(updatedInput: input))
        }
        let message: [String: JSONValue] = ["to": .string("parent"), "message": .string("hi")]
        #expect(PlumeMCPServer.decision(toolName: "mcp__plume__send_message", input: message, permissionMode: .manual)
            == .allow(updatedInput: message))
    }

    @Test func planModeRefusesAStart() {
        let input: [String: JSONValue] = ["initiation": .string("user_asked")]
        #expect(PlumeMCPServer.decision(toolName: "mcp__plume__start_session", input: input, permissionMode: .plan)
            == .deny(message: ChildSessionError.parentInPlanMode.message))
    }

    @Test func anUnknownServerAnswersRequestsOnly() {
        let reply = PlumeMCPServer.unknownServerReply(to: request(1, "tools/list"), named: "other")
        #expect(reply?["error"]?["code"] == .number(-32601))
        let notification: JSONValue = .object(["method": .string("notifications/initialized")])
        #expect(PlumeMCPServer.unknownServerReply(to: notification, named: "other") == nil)
    }
}
