import Foundation
import Testing
@testable import Plume

/// Covers `HeadlessSession`'s message queue without starting a real process.
/// With no process to write to, `submit(text:)` keeps the text queued rather
/// than dropping it, so both messages land in the queue and
/// `removeQueuedMessage(at:)` can be exercised against it.
@MainActor
struct HeadlessSessionQueueTests {
    private func makeSession() -> HeadlessSession {
        HeadlessSession(tabID: UUID(), taskID: UUID())
    }

    @Test func removeQueuedMessageReturnsAndRemovesTheText() {
        let session = makeSession()
        session.submit(text: "first")
        session.submit(text: "second")
        #expect(session.queuedMessages == ["first", "second"])

        let removed = session.removeQueuedMessage(at: 1)

        #expect(removed == "second")
        #expect(session.queuedMessages == ["first"])
    }

    @Test func removeQueuedMessageReturnsNilForOutOfRangeIndex() {
        let session = makeSession()
        session.submit(text: "first")
        session.submit(text: "second")

        let removed = session.removeQueuedMessage(at: 5)

        #expect(removed == nil)
        #expect(session.queuedMessages == ["first", "second"])
    }
}

/// A send that cannot reach a process must keep the user's text and say so,
/// rather than reporting a turn that never started. Losing the message to a
/// silent drop is what made a dead session look like a hang.
@MainActor
struct HeadlessSessionDeadProcessTests {
    @Test func submittingWithNoProcessKeepsTheTextAndReportsIt() {
        let session = HeadlessSession(tabID: UUID(), taskID: UUID())

        session.submit(text: "hello")

        #expect(session.queuedMessages == ["hello"])
        #expect(session.isWorking == false)
        #expect(session.lastError != nil)
    }
}
