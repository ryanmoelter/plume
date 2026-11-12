import Foundation
import Testing
@testable import Plume

/// A headless session serves Plume's MCP server over `mcp_message`, allows
/// its tools without asking, reports whether a finished turn carried a
/// message Plume sent, and puts held notes in front of the user's next
/// message. Line shapes come from probing `claude -p` 2.1.321.
@MainActor
struct HeadlessChildSessionTests {
    private final class Recorder {
        var lines: [String] = []
        var outcomes: [AgentTurnOutcome] = []
    }

    private func makeSession(server: Bool = true) -> (HeadlessSession, Recorder) {
        let engine = StatusEngine(backgroundTasks: BackgroundTaskTracker())
        let session = HeadlessSession(tabID: UUID(), taskID: UUID(), statusEngine: engine)
        session.queuedMessageDelivery = { .endOfTurn }
        engine.register(tabID: session.tabID, taskID: session.taskID)
        let recorder = Recorder()
        session.debugLineSink = { recorder.lines.append($0) }
        session.onTurnFinished = { recorder.outcomes.append($0) }
        if server {
            session.mcpServer = PlumeMCPServer(role: { .parent }) { _ in .success("ok") }
        }
        return (session, recorder)
    }

    private func json(_ line: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
    }

    private func receive(_ session: HeadlessSession, _ line: String) throws {
        session.handle(try #require(StreamJSONDecoder.decode(line: line)))
    }

    private func waitForLines(_ recorder: Recorder, count: Int) async {
        for _ in 0..<200 where recorder.lines.count < count { await Task.yield() }
    }

    private static let result = #"{"type":"result","subtype":"success","is_error":false,"result":"DONE"}"#

    // MARK: - mcp_message

    @Test func anMCPRequestIsAnsweredWithItsReply() async throws {
        let (session, recorder) = makeSession()
        try receive(session, #"{"type":"control_request","request_id":"m1","request":{"subtype":"mcp_message","server_name":"plume","message":{"method":"tools/list","jsonrpc":"2.0","id":1}}}"#)
        await waitForLines(recorder, count: 1)

        let line = try json(try #require(recorder.lines.first))
        #expect(line["type"]?.stringValue == "control_response")
        let response = try #require(line["response"])
        #expect(response["subtype"]?.stringValue == "success")
        #expect(response["request_id"]?.stringValue == "m1")
        let reply = try #require(response["response"]?["mcp_response"])
        #expect(reply["id"] == .number(1))
        #expect(reply["result"]?["tools"]?.arrayValue?.count == 2)
    }

    @Test func aNotificationIsAcknowledgedWithAnEmptyResponse() async throws {
        let (session, recorder) = makeSession()
        try receive(session, #"{"type":"control_request","request_id":"m2","request":{"subtype":"mcp_message","server_name":"plume","message":{"method":"notifications/initialized","jsonrpc":"2.0"}}}"#)
        await waitForLines(recorder, count: 1)

        let line = try json(try #require(recorder.lines.first))
        #expect(line["response"]?["request_id"]?.stringValue == "m2")
        #expect(line["response"]?["response"]?.objectValue == [:])
    }

    @Test func aSessionWithoutTheServerRefusesTheRequest() throws {
        let (session, recorder) = makeSession(server: false)
        try receive(session, #"{"type":"control_request","request_id":"m3","request":{"subtype":"mcp_message","server_name":"plume","message":{"method":"tools/list","jsonrpc":"2.0","id":4}}}"#)

        let line = try json(try #require(recorder.lines.first))
        #expect(line["response"]?["response"]?["mcp_response"]?["error"]?["code"] == .number(-32601))
    }

    // MARK: - Permissions

    @Test func plumesToolsAreAllowedWithoutAsking() throws {
        let (session, recorder) = makeSession()
        try receive(session, #"{"type":"control_request","request_id":"p1","request":{"subtype":"can_use_tool","tool_name":"mcp__plume__start_session","input":{"title":"t"},"mcp_server":{"name":"plume","source":"sdk"}}}"#)

        let line = try json(try #require(recorder.lines.first))
        #expect(line["response"]?["request_id"]?.stringValue == "p1")
        #expect(line["response"]?["response"]?["behavior"]?.stringValue == "allow")
        #expect(session.pendingPermissions.isEmpty)
    }

    @Test func otherToolsStillAsk() throws {
        let (session, recorder) = makeSession()
        try receive(session, #"{"type":"control_request","request_id":"p2","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"ls"}}}"#)

        #expect(recorder.lines.isEmpty)
        #expect(session.pendingPermissions.count == 1)
    }

    // MARK: - Turns Plume started

    @Test func aTurnCarryingAHostMessageReportsAsHostDriven() throws {
        let (session, recorder) = makeSession()
        session.submitFromHost(blocks: [.text("note")])
        try receive(session, Self.result)
        session.submit(text: "typed")
        try receive(session, Self.result)

        #expect(recorder.outcomes.map(\.isHostDriven) == [true, false])
        #expect(recorder.outcomes.first?.text == "DONE")
    }

    @Test func aQueuedHostMessageMarksTheTurnThatCarriesIt() throws {
        let (session, recorder) = makeSession()
        session.submit(text: "typed")
        session.submitFromHost(blocks: [.text("note")])
        try receive(session, Self.result)
        try receive(session, Self.result)

        #expect(recorder.outcomes.map(\.isHostDriven) == [false, true])
    }

    @Test func thePreambleGoesInFrontOfTheUsersMessageOnly() throws {
        let (session, recorder) = makeSession()
        var preamble: String? = "NOTE"
        session.userMessagePreamble = { defer { preamble = nil }; return preamble }

        session.submit(text: "hi")
        try receive(session, Self.result)
        session.submitFromHost(blocks: [.text("from host")])

        let texts = try recorder.lines.map { try json($0)["message"]?["content"]?.arrayValue?.first?["text"]?.stringValue }
        #expect(texts == ["NOTE\n\nhi", "from host"])
    }

    // MARK: - Wire

    @Test func initializeNamesTheSDKServerOnlyWhenAsked() throws {
        let plain = try json(StreamJSONEncoder.initialize(requestID: "i1") ?? "")
        #expect(plain["request"]?["sdkMcpServers"] == nil)
        let served = try json(StreamJSONEncoder.initialize(requestID: "i2", sdkMcpServers: ["plume"]) ?? "")
        #expect(served["request"]?["sdkMcpServers"] == .array([.string("plume")]))
    }

    @Test func anMCPMessageDecodesWithItsServerAndMessage() throws {
        let message = try #require(StreamJSONDecoder.decode(line: #"{"type":"control_request","request_id":"m1","request":{"subtype":"mcp_message","server_name":"plume","message":{"method":"ping","jsonrpc":"2.0","id":9}}}"#))
        guard case .controlRequest(let request) = message else {
            Issue.record("expected a control request")
            return
        }
        #expect(request.subtype == "mcp_message")
        #expect(request.serverName == "plume")
        #expect(request.message?["method"]?.stringValue == "ping")
    }
}
