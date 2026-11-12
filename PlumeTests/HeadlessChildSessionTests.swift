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

    private func sentTexts(_ recorder: Recorder) throws -> [String?] {
        try recorder.lines.map { try json($0)["message"]?["content"]?.arrayValue?.first?["text"]?.stringValue }
    }

    @Test func aQueuedMessageTakesThePreambleOnlyWhenItIsSent() throws {
        let (session, recorder) = makeSession()
        var asked = 0
        session.userMessagePreamble = { asked += 1; return asked == 1 ? "NOTE" : nil }

        session.submitFromHost(blocks: [.text("host")])
        session.submit(text: "typed")
        #expect(session.queuedMessages == [[.text("typed")]])
        #expect(asked == 0)

        try receive(session, Self.result)
        #expect(try sentTexts(recorder) == ["host", "NOTE\n\ntyped"])
    }

    @Test func aQueuedHostMessageShowsItsDisplayAndSendsItsWire() throws {
        let (session, recorder) = makeSession()
        session.submit(text: "typed")
        session.submitFromHost(blocks: [.text("<system-reminder>x</system-reminder>")], display: [.text("Stop")])
        #expect(session.queuedMessages == [[.text("Stop")]])

        try receive(session, Self.result)
        try receive(session, Self.result)

        #expect(try sentTexts(recorder) == ["typed", "<system-reminder>x</system-reminder>"])
        #expect(recorder.outcomes.map(\.isHostDriven) == [false, true])
    }

    @Test func removingAQueuedHostMessageHandsItBackToTheHost() throws {
        let (session, recorder) = makeSession()
        var returned: [HostMessage] = []
        session.onHostMessagesReturned = { returned += $0 }
        session.submit(text: "typed")
        session.submitFromHost(blocks: [.text("wire")], display: [.text("same")], origin: .fromParent(text: "same"))

        #expect(!session.canEditQueuedMessage(at: 0))
        #expect(session.removeQueuedMessage(at: 0) == nil)
        #expect(returned.map(\.origin) == [.fromParent(text: "same")])

        session.submit(text: "same")
        try receive(session, Self.result)
        #expect(try sentTexts(recorder) == ["typed", "same"])
        #expect(recorder.outcomes.map(\.isHostDriven) == [false])
    }

    @Test func identicalTextFromTheHostAndTheUserKeepsEachRole() throws {
        let (session, recorder) = makeSession()
        var returned: [HostMessage] = []
        session.onHostMessagesReturned = { returned += $0 }
        session.submit(text: "first")
        session.submit(text: "same")
        session.submitFromHost(blocks: [.text("wire")], display: [.text("same")])
        #expect(session.queuedMessages == [[.text("same")], [.text("same")]])
        #expect(session.canEditQueuedMessage(at: 0))
        #expect(!session.canEditQueuedMessage(at: 1))

        #expect(session.removeQueuedMessage(at: 0) == [.text("same")])
        #expect(returned.isEmpty)
        try receive(session, Self.result)
        try receive(session, Self.result)

        #expect(try sentTexts(recorder) == ["first", "wire"])
        #expect(recorder.outcomes.map(\.isHostDriven) == [false, true])
    }

    @Test func withdrawingTheOnlyHostMessageInATurnLeavesItUserDriven() throws {
        let (session, recorder) = makeSession()
        var returned: [HostMessage] = []
        session.onHostMessagesReturned = { returned += $0 }
        var handedBack: [UserContentBlock]? = [.text("unset")]
        session.submit(text: "typed")
        session.submitFromHost(blocks: [.text("wire")], display: [.text("shown")], origin: .fromParent(text: "shown"))
        session.sendNow(appending: [])
        let delivering = try #require(session.deliveringMessages.first)
        #expect(!delivering.isEditable)

        session.withdrawDeliveringMessage(id: delivering.id) { handedBack = $0 }
        let request = try json(try #require(recorder.lines.last))
        let requestID = try #require(request["request_id"]?.stringValue)
        try receive(session, #"{"type":"control_response","response":{"subtype":"success","request_id":""# + requestID + #"","response":{"cancelled":true}}}"#)
        try receive(session, Self.result)

        #expect(handedBack == nil)
        #expect(returned.map(\.wire) == [[.text("wire")]])
        #expect(recorder.outcomes.map(\.isHostDriven) == [false])
    }

    @Test func aHostMessageStillArrivingWhenTheGraceEndsMarksTheNextTurn() async throws {
        let (session, recorder) = makeSession()
        session.deliveryGrace = .zero
        session.submit(text: "typed")
        session.submitFromHost(blocks: [.text("wire")])
        session.sendNow(appending: [])
        try receive(session, Self.result)
        for _ in 0..<1000 where recorder.outcomes.isEmpty { await Task.yield() }

        try receive(session, #"{"type":"system","subtype":"status","status":"requesting"}"#)
        try receive(session, Self.result)

        #expect(recorder.outcomes.map(\.isHostDriven) == [false, true])
    }

    @Test func sendNowAfterAnExitMergesTheQueueKeepingItsHostMessage() throws {
        let (session, _) = makeSession()
        session.submit(text: "typed")
        session.submitFromHost(blocks: [.text("wire")], display: [.text("shown")])
        session.debugExit(status: 1, errorLine: "boom")

        session.sendNow(appending: [.text("draft")])

        #expect(session.queuedMessages == [[.text("shown\n\ndraft")]])
        let (resumed, recorder) = makeSession()
        for message in session.queue { resumed.submit(message) }
        #expect(try sentTexts(recorder) == ["wire\n\ndraft"])
        try receive(resumed, Self.result)
        #expect(recorder.outcomes.map(\.isHostDriven) == [true])
    }

    @Test func aRequeuedHostMessageKeepsItsMarkerInTheResumedSession() throws {
        let (session, _) = makeSession()
        session.submit(text: "typed")
        session.submitFromHost(blocks: [.text("wire")], display: [.text("shown")])
        session.debugExit(status: 1, errorLine: "boom")

        let (resumed, recorder) = makeSession()
        resumed.inherit(from: session)
        for message in session.queue { resumed.submit(message) }
        try receive(resumed, Self.result)

        #expect(try sentTexts(recorder) == ["wire"])
        #expect(recorder.outcomes.map(\.isHostDriven) == [true])
    }

    @Test func anExitMidTurnReportsAnErrorOutcome() throws {
        let (session, recorder) = makeSession()
        session.submitFromHost(blocks: [.text("brief")])
        session.debugExit(status: 1, errorLine: "API down")

        let outcome = try #require(recorder.outcomes.first)
        #expect(outcome.exitedMidTurn)
        #expect(outcome.isError)
        #expect(outcome.isHostDriven)
        #expect(ChildSessionFormats.reportText(of: outcome) == "The session exited before finishing its turn: API down")
    }

    @Test func anExitBetweenTurnsReportsNothing() {
        let (session, recorder) = makeSession()
        session.debugExit(status: 0, errorLine: nil)
        #expect(recorder.outcomes.isEmpty)
    }

    @Test func aWithdrawnPreambleRidesWithNewerNotes() throws {
        let (session, recorder) = makeSession()
        var notes = ["OLD", "NEW"]
        session.userMessagePreamble = { notes.isEmpty ? nil : notes.removeFirst() }
        session.submitFromHost(blocks: [.text("host")])
        session.sendNow(appending: [.text("first")])
        let delivering = try #require(session.deliveringMessages.first)
        session.withdrawDeliveringMessage(id: delivering.id)
        let request = try json(try #require(recorder.lines.last))
        let requestID = try #require(request["request_id"]?.stringValue)
        try receive(session, #"{"type":"control_response","response":{"subtype":"success","request_id":""# + requestID + #"","response":{"cancelled":true}}}"#)
        try receive(session, Self.result)

        session.submit(text: "second")

        #expect(try sentTexts(recorder).last == "OLD\n\nNEW\n\nsecond")
        #expect(notes.isEmpty)
    }

    @Test func aSlashCommandLeavesThePreambleForTheNextMessage() throws {
        let (session, recorder) = makeSession()
        var preamble: String? = "NOTE"
        session.userMessagePreamble = { defer { preamble = nil }; return preamble }

        session.submit(text: "/effort high")
        try receive(session, Self.result)
        session.submit(text: "hi")

        let texts = try recorder.lines.map { try json($0)["message"]?["content"]?.arrayValue?.first?["text"]?.stringValue }
        #expect(texts == ["/effort high", "NOTE\n\nhi"])
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
