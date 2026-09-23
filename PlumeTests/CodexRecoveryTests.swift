import Foundation
import Testing
@testable import Plume

@MainActor
struct CodexRecoveryTests {
    @MainActor
    private final class Harness {
        var client: CodexAppServerClient!
        var requests: [JSONValue] = []
        var failResume = false

        init() {
            client = CodexAppServerClient { [weak self] line in
                guard let self,
                      let request = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)),
                      let method = request["method"]?.stringValue else { return true }
                requests.append(request)
                guard let id = request["id"], method != "turn/start" else { return true }
                if method == "thread/resume", failResume {
                    reply(id: id, error: .object(["code": .number(-1), "message": .string("Thread unavailable")]))
                } else {
                    let result: JSONValue = switch method {
                    case "thread/resume", "thread/start": .object([
                        "thread": .object(["id": .string("thread")]),
                        "model": .string("gpt-6-astra"), "reasoningEffort": .string("medium")
                    ])
                    default: .object(["data": .array([])])
                    }
                    reply(id: id, result: result)
                }
                return true
            }
        }

        func reply(id: JSONValue, result: JSONValue = .object([:]), error: JSONValue? = nil) {
            let object: JSONValue = error.map { .object(["id": id, "error": $0]) }
                ?? .object(["id": id, "result": result])
            let data = try! JSONEncoder().encode(object)
            client.receive(String(decoding: data, as: UTF8.self))
        }

        var turns: [JSONValue] { requests.filter { $0["method"] == .string("turn/start") } }
        var interrupts: [JSONValue] { requests.filter { $0["method"] == .string("turn/interrupt") } }
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<10_000 {
            if condition() { return }
            await Task.yield()
        }
        Issue.record("Protocol task did not settle")
        throw CancellationError()
    }

    @Test func failedResumeBecomesRetryableWithoutStartingANewThread() async throws {
        let h = Harness()
        h.failResume = true
        let session = CodexSession(tabID: UUID(), taskID: UUID(), client: h.client)
        defer { session.stop() }
        session.start(workingDirectory: nil, resumeThreadID: "thread", model: nil, environment: [:])
        session.submit(text: "still unsent")
        try await waitFor { session.hasExited }
        #expect(session.queuedMessages.map(\.plainText) == ["still unsent"])
        #expect(h.turns.isEmpty)
        #expect(!h.requests.contains { $0["method"] == .string("thread/start") })
        #expect(session.lastError?.contains("Thread unavailable") == true)
    }

    @Test func disconnectDoesNotRequeueAnUncertainTurn() async throws {
        let h = Harness()
        let session = CodexSession(tabID: UUID(), taskID: UUID(), client: h.client)
        defer { session.stop() }
        session.start(workingDirectory: nil, resumeThreadID: "thread", model: nil, environment: [:])
        session.submit(text: "possibly accepted")
        try await waitFor { h.turns.count == 1 }
        session.submit(text: "definitely unsent")
        h.client.handleExit(status: 1, message: "Lost connection")
        await Task.yield()
        #expect(session.hasExited)
        #expect(session.sessionID == "thread")
        #expect(session.queuedMessages.map(\.plainText) == ["definitely unsent"])
        #expect(h.turns.count == 1)
    }

    @Test func lateStartReplyCannotRestartACompletedTurn() async throws {
        let h = Harness()
        let session = CodexSession(tabID: UUID(), taskID: UUID(), client: h.client)
        defer { session.stop() }
        session.start(workingDirectory: nil, resumeThreadID: nil, model: nil, environment: [:])
        session.submit(text: "one")
        try await waitFor { h.turns.count == 1 }
        session.submit(text: "two")
        h.client.receive(#"{"method":"turn/started","params":{"threadId":"thread","turn":{"id":"t1"}}}"#)
        h.client.receive(#"{"method":"turn/completed","params":{"threadId":"thread","turn":{"id":"t1","status":"completed"}}}"#)
        #expect(!session.isWorking)
        h.reply(id: try #require(h.turns.first?["id"]), result: .object(["turn": .object(["id": .string("t1")])]))
        try await waitFor { h.turns.count == 2 }
        #expect(session.queuedMessages.isEmpty)
        #expect(session.isWorking)
        #expect(h.turns.last?["params"]?["input"]?.arrayValue?.first?["text"] == .string("two"))
    }

    @Test func interruptedTurnKeepsQueuedFollowupUnsentAfterLateReply() async throws {
        let h = Harness()
        let session = CodexSession(tabID: UUID(), taskID: UUID(), client: h.client)
        defer { session.stop() }
        session.start(workingDirectory: nil, resumeThreadID: nil, model: nil, environment: [:])
        session.submit(text: "one")
        try await waitFor { h.turns.count == 1 }
        session.submit(text: "two")
        h.client.receive(#"{"method":"turn/completed","params":{"threadId":"thread","turn":{"id":"t1","status":"interrupted"}}}"#)
        h.reply(id: try #require(h.turns.first?["id"]))
        await Task.yield()
        #expect(h.turns.count == 1)
        #expect(session.queuedMessages.map(\.plainText) == ["two"])
        #expect(!session.isWorking)
    }

    @Test func terminalErrorKeepsQueuedFollowupUnsentAfterLateReply() async throws {
        let h = Harness()
        let session = CodexSession(tabID: UUID(), taskID: UUID(), client: h.client)
        defer { session.stop() }
        session.start(workingDirectory: nil, resumeThreadID: nil, model: nil, environment: [:])
        session.submit(text: "one")
        try await waitFor { h.turns.count == 1 }
        session.submit(text: "two")

        h.client.receive(#"{"method":"error","params":{"threadId":"thread","turnId":"t1","willRetry":false,"error":{"message":"terminal failure"}}}"#)
        h.reply(
            id: try #require(h.turns.first?["id"]),
            result: .object(["turn": .object(["id": .string("t1")])])
        )
        await Task.yield()

        #expect(h.turns.count == 1)
        #expect(session.queuedMessages.map(\.plainText) == ["two"])
        #expect(!session.isWorking)
        #expect(session.lastError == "terminal failure")
    }

    @Test func interruptBeforeTurnIDIsDeliveredWhenStartReplies() async throws {
        let h = Harness()
        let session = CodexSession(tabID: UUID(), taskID: UUID(), client: h.client)
        defer { session.stop() }
        session.start(workingDirectory: nil, resumeThreadID: nil, model: nil, environment: [:])
        session.submit(text: "one")
        try await waitFor { h.turns.count == 1 }

        session.interrupt()
        await Task.yield()
        #expect(h.interrupts.isEmpty)

        h.reply(
            id: try #require(h.turns.first?["id"]),
            result: .object(["turn": .object(["id": .string("t1")])])
        )
        try await waitFor { h.interrupts.count == 1 }
        #expect(h.interrupts.first?["params"]?["threadId"] == .string("thread"))
        #expect(h.interrupts.first?["params"]?["turnId"] == .string("t1"))
    }

    @Test func zeroStatusAppServerExitIsStillAnError() async throws {
        let h = Harness()
        let tabID = UUID()
        let taskID = UUID()
        let session = CodexSession(tabID: tabID, taskID: taskID, client: h.client)
        defer { session.stop() }
        session.start(workingDirectory: nil, resumeThreadID: nil, model: nil, environment: [:])
        try await waitFor { session.sessionID == "thread" }

        h.client.handleExit(status: 0, message: nil)
        #expect(session.hasExited)
        #expect(StatusEngine.shared.ownStatus(forTab: tabID) == .error)
        #expect(session.lastError?.contains("disconnected") == true)
    }

    @Test func queuedImageOnlyTurnRetainsPayloadThroughSubmissionAndEditing() async throws {
        let h = Harness()
        let session = CodexSession(tabID: UUID(), taskID: UUID(), client: h.client)
        defer { session.stop() }
        let image = ChatImage(mediaType: "image/png", base64: "aW1hZ2U=")
        let blocks: [UserContentBlock] = [.image(image)]
        #expect(session.submit(blocks: blocks) == .queued)
        #expect(session.removeQueuedMessage(at: 0) == blocks)
        session.submit(blocks: blocks)
        session.start(workingDirectory: nil, resumeThreadID: nil, model: nil, environment: [:])
        try await waitFor { h.turns.count == 1 }
        #expect(h.turns[0]["params"]?["input"] == .array([
            .object(["type": .string("image"), "url": .string("data:image/png;base64,aW1hZ2U=")])
        ]))
    }

    @Test func imagesSurviveDefinitelyUnsentTransportFailure() async throws {
        let h = Harness()
        let session = CodexSession(tabID: UUID(), taskID: UUID(), client: h.client)
        defer { session.stop() }
        session.start(workingDirectory: nil, resumeThreadID: nil, model: nil, environment: [:])
        session.submit(text: "first")
        try await waitFor { h.turns.count == 1 }
        h.reply(id: try #require(h.turns.first?["id"]), result: .object(["turn": .object(["id": .string("initial")])]))
        try await waitFor { session.canSteer }
        h.client.receive(#"{"method":"turn/completed","params":{"threadId":"thread","turn":{"id":"initial","status":"completed"}}}"#)
        h.client.stop()
        let blocks: [UserContentBlock] = [.text("Keep this"), .image(.init(mediaType: "image/png", base64: "aW1hZ2U="))]
        session.submit(blocks: blocks)
        try await waitFor { !session.queuedMessages.isEmpty }
        #expect(session.queuedMessages == [blocks])
    }

}
