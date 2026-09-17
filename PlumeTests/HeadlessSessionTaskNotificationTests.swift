import Foundation
import Testing
@testable import Plume

/// A background task's completion notification starts a turn the host never
/// asked for, so the first assistant envelope is the only thing that can
/// report it. Without that the tab reads `awaitingReply` for the whole turn.
@MainActor
struct HeadlessSessionTaskNotificationTests {
    private func makeSession() -> HeadlessSession {
        HeadlessSession(tabID: UUID(), taskID: UUID())
    }

    private func assistantEnvelope() throws -> StreamJSONMessage {
        try #require(StreamJSONDecoder.decode(
            line: #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"On it"}]}}"#
        ))
    }

    private func result() throws -> StreamJSONMessage {
        try #require(StreamJSONDecoder.decode(
            line: #"{"type":"result","subtype":"success","is_error":false,"result":"done"}"#
        ))
    }

    @Test func anUnpromptedAssistantMessageStartsATurn() throws {
        let session = makeSession()
        StatusEngine.shared.register(tabID: session.tabID, taskID: session.taskID)

        session.handle(try assistantEnvelope())

        #expect(session.isWorking)
        #expect(StatusEngine.shared.ownStatus(forTab: session.tabID) == .working)
    }

    @Test func theTurnEndsOnItsResult() throws {
        let session = makeSession()
        StatusEngine.shared.register(tabID: session.tabID, taskID: session.taskID)

        session.handle(try assistantEnvelope())
        session.handle(try result())

        #expect(!session.isWorking)
        #expect(StatusEngine.shared.ownStatus(forTab: session.tabID) == .awaitingReply)
    }

    @Test func anEnvelopeAfterTheProcessExitedStartsNothing() throws {
        let session = makeSession()
        StatusEngine.shared.register(tabID: session.tabID, taskID: session.taskID)
        session.stop()

        session.handle(try assistantEnvelope())

        #expect(!session.isWorking)
        #expect(StatusEngine.shared.ownStatus(forTab: session.tabID) == .notStarted)
    }

    /// The streamed text belongs to the previous turn until `message_start`
    /// replaces it; clearing it here would blank the chat mid-handoff.
    @Test func anUnpromptedTurnKeepsTheStreamedText() throws {
        let session = makeSession()
        StatusEngine.shared.register(tabID: session.tabID, taskID: session.taskID)
        session.handle(try #require(StreamJSONDecoder.decode(
            line: #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"hello"}}}"#
        )))

        session.handle(try assistantEnvelope())

        #expect(session.streamingText == "hello")
    }
}
