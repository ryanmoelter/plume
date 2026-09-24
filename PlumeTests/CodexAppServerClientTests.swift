import Foundation
import Testing

@testable import Plume

@MainActor
struct CodexRPCDecodingTests {
    @Test func aMethodWithAnIDIsAServerRequest() throws {
        let incoming = CodexRPC.decode(
            line: #"{"id":7,"method":"item/commandExecution/requestApproval","params":{"itemId":"a"}}"#
        )
        guard case .serverRequest(let id, let method, _)? = incoming else {
            Issue.record("expected a server request, got \(String(describing: incoming))")
            return
        }
        #expect(id == .number(7))
        #expect(method == "item/commandExecution/requestApproval")
    }

    @Test func aMethodWithoutAnIDIsANotification() throws {
        let incoming = CodexRPC.decode(line: #"{"method":"turn/started","params":{}}"#)
        guard case .notification(let method, _)? = incoming else {
            Issue.record("expected a notification")
            return
        }
        #expect(method == "turn/started")
    }

    /// The server omits `jsonrpc` on every line, so requiring it would drop
    /// the whole stream.
    @Test func aReplyWithoutAJSONRPCFieldStillDecodes() throws {
        let incoming = CodexRPC.decode(line: #"{"id":1,"result":{"thread":{"id":"t1"}}}"#)
        guard case .response(let id, _)? = incoming else {
            Issue.record("expected a response")
            return
        }
        #expect(id == .number(1))
    }

    @Test func anErrorReplyDecodesAsAFailure() throws {
        let incoming = CodexRPC.decode(line: #"{"id":2,"error":{"code":-32601,"message":"nope"}}"#)
        guard case .failure(_, let error)? = incoming else {
            Issue.record("expected a failure")
            return
        }
        #expect(error.code == -32601)
        #expect(error.message == "nope")
    }

    @Test func aStringRequestIDSurvives() throws {
        let incoming = CodexRPC.decode(line: #"{"id":"abc","method":"item/tool/call","params":{}}"#)
        guard case .serverRequest(let id, _, _)? = incoming else {
            Issue.record("expected a server request")
            return
        }
        #expect(id == .string("abc"))
    }

    @Test func garbageDecodesToNothingRatherThanCrashing() {
        #expect(CodexRPC.decode(line: "not json") == nil)
        #expect(CodexRPC.decode(line: "") == nil)
    }
}

@MainActor
struct CodexAppServerClientTests {
    /// Collects what the client writes, standing in for the subprocess.
    private func makeClient() -> (CodexAppServerClient, () -> [String]) {
        let sent = Box()
        let client = CodexAppServerClient { line in
            sent.lines.append(line)
            return true
        }
        return (client, { sent.lines })
    }

    private final class Box {
        var lines: [String] = []
    }

    @Test func aReplyResumesTheMatchingRequest() async throws {
        let (client, sent) = makeClient()
        let reply = Task { try await client.send("thread/start", .object(["cwd": .string("/tmp")])) }

        try await waitUntil { !sent().isEmpty }
        let id = try #require(requestID(in: sent()[0]))
        client.receive(#"{"id":\#(id),"result":{"ok":true}}"#)

        #expect(try await reply.value == .object(["ok": .bool(true)]))
    }

    @Test func anErrorReplyThrowsTheServersMessage() async throws {
        let (client, sent) = makeClient()
        let reply = Task { try await client.send("nope") }

        try await waitUntil { !sent().isEmpty }
        let id = try #require(requestID(in: sent()[0]))
        client.receive(#"{"id":\#(id),"error":{"code":-32601,"message":"unknown"}}"#)

        let failure = await reply.result.failure()
        #expect(failure == .server(code: -32601, message: "unknown"))
    }

    /// The bug this guards is silent: a request whose reply can never arrive
    /// leaves its caller awaiting forever, and the chat's turn with it.
    @Test func processExitFailsEveryRequestStillInFlight() async throws {
        let (client, sent) = makeClient()
        let first = Task { try await client.send("thread/start") }
        let second = Task { try await client.send("model/list") }

        try await waitUntil { sent().count == 2 }
        client.handleExit(status: 1, message: "codex: command not found")

        let expected = CodexAppServerClient.Failure.exited(status: 1, message: "codex: command not found")
        #expect(await first.result.failure() == expected)
        #expect(await second.result.failure() == expected)
    }

    @Test func sendingWithNoTransportFailsRatherThanHanging() async {
        let client = CodexAppServerClient()
        await #expect(throws: CodexAppServerClient.Failure.notRunning) {
            try await client.send("thread/start")
        }
    }

    /// An unanswered server request stalls the turn, so anything Plume does
    /// not implement must still get a reply.
    @Test func anUnhandledServerRequestIsAnsweredWithAnError() async throws {
        let (client, sent) = makeClient()
        client.receive(#"{"id":9,"method":"item/tool/call","params":{}}"#)

        try await waitUntil { !sent().isEmpty }
        #expect(sent()[0].contains("\"error\""))
        #expect(sent()[0].contains("item/tool/call"))
    }

    @Test func anUnknownNotificationIsDeliveredRatherThanDropped() async throws {
        let (client, _) = makeClient()
        var seen: String?
        client.onNotification = { method, _ in seen = method }
        client.receive(#"{"method":"some/future/event","params":{}}"#)
        #expect(seen == "some/future/event")
    }

    private func requestID(in line: String) -> Int? {
        guard let data = line.data(using: .utf8),
              case .object(let fields)? = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .number(let id)? = fields["id"]
        else { return nil }
        return Int(id)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("condition never became true")
    }
}

private extension Result where Failure == Error {
    /// The thrown error, as the concrete failure the client reports.
    func failure() -> CodexAppServerClient.Failure? {
        if case .failure(let error) = self { return error as? CodexAppServerClient.Failure }
        return nil
    }
}
