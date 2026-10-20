import Foundation
import Testing
@testable import Plume

@MainActor
struct MergedTurnTests {
    private let image = ChatImage(mediaType: "image/png", base64: "abc")

    @Test func messagesMergeInOrderAndKeepTheirImages() {
        let merged = [[.text("one")], [.text("two"), .image(image)], [.text("draft")]].mergedIntoOneTurn

        #expect(merged == [.text("one\n\ntwo"), .image(image), .text("draft")])
    }

    @Test func emptyTextDropsAndAnImageOnlyMessageSurvives() {
        let merged = [[.text("  ")], [.image(image)], [.text("after")]].mergedIntoOneTurn

        #expect(merged == [.image(image), .text("after")])
    }

    @Test func interruptCarriesCancelQueuedOnlyWhenAsked() throws {
        let plain = try #require(StreamJSONEncoder.interrupt(requestID: "a"))
        let cancelling = try #require(StreamJSONEncoder.interrupt(requestID: "b", cancelQueued: true))
        let root = try JSONDecoder().decode(JSONValue.self, from: Data(cancelling.utf8))

        #expect(!plain.contains("cancel_queued"))
        #expect(root["request"]?["subtype"]?.stringValue == "interrupt")
        #expect(root["request"]?["cancel_queued"] == .bool(true))
    }

    @Test func aUserTurnCarriesPriorityOnlyWhenAsked() throws {
        let plain = try #require(StreamJSONEncoder.userTurn(blocks: [.text("hi")]))
        let next = try #require(StreamJSONEncoder.userTurn(blocks: [.text("hi")], priority: .next))
        let root = try JSONDecoder().decode(JSONValue.self, from: Data(next.utf8))

        #expect(!plain.contains("priority"))
        #expect(root["type"]?.stringValue == "user")
        #expect(root["priority"]?.stringValue == "next")
    }
}

/// Send-now on the headless transport. Mid-turn, the queue and the draft go
/// into the running turn as one `priority: "next"` message, with no interrupt,
/// and show as delivering until the CLI's next request carries them. If the
/// turn's `result` comes first, the CLI runs the message as its own turn
/// straight after, so the turn's end is held rather than announced.
///
/// Line shapes come from a recorded `claude -p` 2.1.304 run.
@MainActor
struct HeadlessSendNowTests {
    private final class Recorder {
        var lines: [String] = []
        var statuses: [TaskStatus] = []
    }

    /// With `recordsLines` false there is no process, so every send fails and
    /// puts its turn back on the queue.
    private func makeSession(recordsLines: Bool = true) -> (HeadlessSession, StatusEngine, Recorder) {
        let engine = StatusEngine(backgroundTasks: BackgroundTaskTracker())
        let session = HeadlessSession(tabID: UUID(), taskID: UUID(), statusEngine: engine)
        engine.register(tabID: session.tabID, taskID: session.taskID)
        let recorder = Recorder()
        engine.setTabStatusObserver("test") { _, _, status, _ in recorder.statuses.append(status) }
        if recordsLines { session.debugLineSink = { recorder.lines.append($0) } }
        return (session, engine, recorder)
    }

    private func decode(_ line: String) throws -> StreamJSONMessage {
        try #require(StreamJSONDecoder.decode(line: line))
    }

    private static let mainAssistant = #"{"type":"assistant","parent_tool_use_id":null,"message":{"role":"assistant","content":[{"type":"text","text":"working"}]}}"#
    private static let requesting = #"{"type":"system","subtype":"status","status":"requesting"}"#
    private static let result = #"{"type":"result","subtype":"success","is_error":false,"result":"DONE"}"#

    private func startTurn(_ session: HeadlessSession) throws {
        session.handle(try decode(Self.mainAssistant))
    }

    private func json(_ line: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
    }

    @Test func midTurnTheQueueGoesIntoTheRunningTurnAsOneMessage() throws {
        let (session, _, recorder) = makeSession()
        try startTurn(session)
        session.submit(text: "one")
        session.submit(text: "two")

        session.sendNow(appending: [.text("draft")])

        #expect(recorder.lines.count == 1)
        let line = try json(try #require(recorder.lines.first))
        #expect(line["type"]?.stringValue == "user")
        #expect(line["priority"]?.stringValue == "next")
        #expect(line["message"]?["content"]?.arrayValue?.first?["text"]?.stringValue == "one\n\ntwo\n\ndraft")
        #expect(session.queuedMessages.isEmpty)
        #expect(session.deliveringMessages == [[.text("one\n\ntwo\n\ndraft")]])
        #expect(session.isWorking)
    }

    @Test func theNextRequestDeliversTheMessageAndTheTurnEndsNormally() throws {
        let (session, engine, recorder) = makeSession()
        try startTurn(session)
        session.sendNow(appending: [.text("also this")])

        session.handle(try decode(Self.requesting))
        #expect(session.deliveringMessages.isEmpty)
        session.handle(try decode(Self.result))

        #expect(!session.isWorking)
        #expect(engine.status(forTab: session.tabID) == .awaitingReply)
        #expect(recorder.statuses == [.working, .awaitingReply])
    }

    /// The CLI's own turn for the message starts about 0.1 s after the
    /// `result`; the gap must not read as the turn being over.
    @Test func aResultBeforeDeliveryHoldsTheTurnForTheOneThatFollows() throws {
        let (session, _, recorder) = makeSession()
        try startTurn(session)
        session.sendNow(appending: [.text("also this")])

        session.handle(try decode(Self.result))
        #expect(session.isWorking)
        session.handle(try decode(Self.requesting))
        #expect(session.deliveringMessages.isEmpty)
        session.handle(try decode(Self.mainAssistant))
        session.handle(try decode(Self.result))

        #expect(!session.isWorking)
        #expect(!recorder.statuses.dropLast().contains(.awaitingReply))
        #expect(recorder.statuses.last == .awaitingReply)
    }

    @Test func aHeldTurnEndsAfterTheGraceWhenNothingFollows() async throws {
        let (session, engine, _) = makeSession()
        session.deliveryGrace = .milliseconds(10)
        try startTurn(session)
        session.sendNow(appending: [.text("also this")])

        session.handle(try decode(Self.result))
        var polls = 0
        while session.isWorking, polls < 500 {
            try await Task.sleep(for: .milliseconds(10))
            polls += 1
        }

        #expect(!session.isWorking)
        #expect(engine.status(forTab: session.tabID) == .awaitingReply)
    }

    @Test func aMessageQueuedDuringTheHoldWaitsForTheFollowingTurn() throws {
        let (session, _, recorder) = makeSession()
        try startTurn(session)
        session.sendNow(appending: [.text("also this")])
        session.submit(text: "later")

        session.handle(try decode(Self.result))
        #expect(recorder.lines.count == 1)
        #expect(session.queuedMessages.map(\.plainText) == ["later"])

        session.handle(try decode(Self.requesting))
        session.handle(try decode(Self.result))
        #expect(recorder.lines.count == 2)
        #expect(session.queuedMessages.isEmpty)
    }

    @Test func sendNowNeverInterrupts() throws {
        let (session, _, recorder) = makeSession()
        try startTurn(session)
        session.submit(text: "one")

        session.sendNow(appending: [])

        #expect(!recorder.lines.contains { $0.contains("interrupt") })
    }

    @Test func aFailedMidTurnSendKeepsTheMergedMessageQueued() throws {
        let (session, _, _) = makeSession(recordsLines: false)
        try startTurn(session)
        session.submit(text: "one")

        session.sendNow(appending: [.text("draft")])

        #expect(session.queuedMessages == [[.text("one\n\ndraft")]])
        #expect(session.deliveringMessages.isEmpty)
    }

    @Test func withNoTurnRunningTheQueueGoesAtOnceAndOnlyOnce() {
        let (session, _, _) = makeSession(recordsLines: false)
        session.submit(text: "one")
        session.submit(text: "two")

        session.sendNow(appending: [.text("draft")])

        #expect(session.queuedMessages == [[.text("one\n\ntwo\n\ndraft")]])
    }

    @Test func withNoTurnRunningTheTurnCarriesNoPriority() throws {
        let (session, _, recorder) = makeSession()

        session.sendNow(appending: [.text("draft")])

        let line = try json(try #require(recorder.lines.last))
        #expect(line["priority"] == nil)
        #expect(session.deliveringMessages.isEmpty)
    }

    @Test func anEmptyDraftWithNothingQueuedDoesNothing() {
        let (session, _, _) = makeSession(recordsLines: false)

        session.sendNow(appending: [.text("  ")])

        #expect(session.queuedMessages.isEmpty)
        #expect(!session.isWorking)
    }
}
