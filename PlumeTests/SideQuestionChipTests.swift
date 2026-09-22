import Foundation
import Testing
@testable import Plume

/// Which side question the chip below the chat shows. Dismissing hides the
/// chip without touching the panel's history, and asking again brings it back
/// — the chip is the only feedback that a `/btw` is running, so a dismissal
/// that silenced later questions would silence the feature.
@MainActor
struct SideQuestionChipTests {
    private func session() -> HeadlessSession {
        HeadlessSession(tabID: UUID(), taskID: UUID(), initialEffort: nil)
    }

    @Test func aTabThatHasAskedNothingShowsNoChip() {
        #expect(session().chippedSideQuestion == nil)
    }

    /// Asking with no process running fails the question immediately, which
    /// still belongs on the chip: a failure is feedback too.
    @Test func askingShowsTheQuestionOnTheChip() {
        let session = session()
        session.askSideQuestion("what file did you edit?")
        #expect(session.chippedSideQuestion?.question == "what file did you edit?")
    }

    @Test func dismissingHidesTheChip() {
        let session = session()
        session.askSideQuestion("first")
        session.dismissChippedSideQuestion()
        #expect(session.chippedSideQuestion == nil)
    }

    /// The bug this guards: keying dismissal to anything but the question's
    /// own id would leave a later question with no feedback at all.
    @Test func askingAgainAfterADismissalShowsTheNewQuestion() {
        let session = session()
        session.askSideQuestion("first")
        session.dismissChippedSideQuestion()
        session.askSideQuestion("second")
        #expect(session.chippedSideQuestion?.question == "second")
    }

    /// Dismissing hides the chip only. The panel lists every exchange, so the
    /// answers stay reachable.
    @Test func dismissingKeepsTheQuestionInTheHistory() {
        let session = session()
        session.askSideQuestion("first")
        session.dismissChippedSideQuestion()
        #expect(session.sideQuestions.count == 1)
    }

    @Test func theChipFollowsTheNewestQuestion() {
        let session = session()
        session.askSideQuestion("first")
        session.askSideQuestion("second")
        #expect(session.chippedSideQuestion?.question == "second")
    }
}
