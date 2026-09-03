import Foundation
import Testing
@testable import Plume

/// Covers `HeadlessSession`'s message queue without starting a real process
/// — `submit(text:)` and `removeQueuedMessage(at:)` only touch in-memory
/// state until a turn is actually sent.
@MainActor
struct HeadlessSessionQueueTests {
    private func makeSession() -> HeadlessSession {
        HeadlessSession(tabID: UUID(), taskID: UUID())
    }

    @Test func removeQueuedMessageReturnsAndRemovesTheText() {
        let session = makeSession()
        session.submit(text: "first")
        session.submit(text: "second")
        #expect(session.queuedMessages == ["second"])

        let removed = session.removeQueuedMessage(at: 0)

        #expect(removed == "second")
        #expect(session.queuedMessages.isEmpty)
    }

    @Test func removeQueuedMessageReturnsNilForOutOfRangeIndex() {
        let session = makeSession()
        session.submit(text: "first")
        session.submit(text: "second")

        let removed = session.removeQueuedMessage(at: 5)

        #expect(removed == nil)
        #expect(session.queuedMessages == ["second"])
    }
}
