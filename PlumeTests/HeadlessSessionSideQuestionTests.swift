import Foundation
import Testing
@testable import Plume

/// `/btw` side questions, driven through `HeadlessSession.handle(_:)` rather
/// than a real process — the same approach `HeadlessSessionQueueTests` uses.
@MainActor
struct HeadlessSessionSideQuestionTests {
    private func makeSession() -> HeadlessSession {
        HeadlessSession(tabID: UUID(), taskID: UUID())
    }

    /// With no process running, `askSideQuestion` cannot reach the wire, so
    /// the exchange is recorded as failed rather than silently dropped.
    @Test func askingWithNoProcessRecordsAFailure() {
        let session = makeSession()

        session.askSideQuestion("what is the meaning of life")

        #expect(session.sideQuestions.count == 1)
        #expect(session.sideQuestions[0].question == "what is the meaning of life")
        guard case .failed = session.sideQuestions[0].state else {
            Issue.record("expected a failed state with no process")
            return
        }
    }

    /// `updateSideQuestion` matches by id regardless of `pendingControlRequests`
    /// bookkeeping, so a progress event still finds the exchange even after
    /// `askSideQuestion` has already given up on it for lack of a process.
    @Test func progressEventMarksTheMatchingExchangeRunning() {
        let session = makeSession()
        session.askSideQuestion("what is X")
        let id = session.sideQuestions[0].id

        session.handle(.controlRequestProgress(requestID: id))

        #expect(session.sideQuestions[0].state == .running)
    }
}
