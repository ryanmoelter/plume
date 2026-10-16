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
}

/// Send-now on the headless transport. There is no process, so every send
/// fails and puts its turn back on the queue — which is what makes the turn
/// that would have gone out readable here.
@MainActor
struct HeadlessSendNowTests {
    private func makeSession() -> HeadlessSession {
        HeadlessSession(
            tabID: UUID(),
            taskID: UUID(),
            statusEngine: StatusEngine(backgroundTasks: BackgroundTaskTracker())
        )
    }

    private func decode(_ line: String) throws -> StreamJSONMessage {
        try #require(StreamJSONDecoder.decode(line: line))
    }

    private func startTurn(_ session: HeadlessSession) throws {
        session.handle(try decode(#"{"type":"assistant","parent_tool_use_id":null,"message":{"role":"assistant","content":[{"type":"text","text":"working"}]}}"#))
    }

    private func result() throws -> StreamJSONMessage {
        try decode(#"{"type":"result","subtype":"error_during_execution","is_error":true}"#)
    }

    @Test func theQueueWaitsForTheInterruptedTurnsResult() throws {
        let session = makeSession()
        try startTurn(session)
        session.submit(text: "one")
        session.submit(text: "two")

        session.sendNow(appending: [.text("draft")])
        #expect(session.queuedMessages.map(\.plainText) == ["one", "two", "draft"])

        session.handle(try result())
        #expect(session.queuedMessages == [[.text("one\n\ntwo\n\ndraft")]])
    }

    @Test func withNoTurnRunningTheQueueGoesAtOnceAndOnlyOnce() {
        let session = makeSession()
        session.submit(text: "one")
        session.submit(text: "two")

        session.sendNow(appending: [.text("draft")])

        #expect(session.queuedMessages == [[.text("one\n\ntwo\n\ndraft")]])
    }

    /// Only the turn after send-now is merged; the one after it goes back to
    /// sending a single queued message.
    @Test func theNextTurnSendsOneMessageAgain() throws {
        let session = makeSession()
        try startTurn(session)
        session.submit(text: "one")
        session.sendNow(appending: [])
        session.handle(try result())

        try startTurn(session)
        session.submit(text: "later")
        session.handle(try result())

        #expect(session.queuedMessages.map(\.plainText) == ["one", "later"])
    }

    @Test func anEmptyDraftWithNothingQueuedDoesNothing() {
        let session = makeSession()

        session.sendNow(appending: [.text("  ")])

        #expect(session.queuedMessages.isEmpty)
        #expect(!session.isWorking)
    }
}
