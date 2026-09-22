import Foundation
import Testing
@testable import Plume

/// A forked tab holds a live session that was launched with no prompt, so it
/// is waiting on the user rather than on its own reply. `hasUserSubmitted` is
/// what tells the two apart; reading the session's mere existence instead
/// deadlocks the tab, because the composer it disables is the only thing that
/// could have ended the wait.
@MainActor
struct ForkedTabComposerTests {
    private func session() -> HeadlessSession {
        HeadlessSession(tabID: UUID(), taskID: UUID(), initialEffort: nil)
    }

    @Test func aSessionGivenNothingIsNotAwaitingItsOwnReply() {
        #expect(!session().hasUserSubmitted)
    }

    @Test func submittingAMessageMarksTheSessionAsAwaitingAReply() {
        let session = session()
        session.submit(blocks: [.text("hello")])
        #expect(session.hasUserSubmitted)
    }

    /// Empty content is not a turn, so it must not flip the tab into the
    /// waiting state either — that would deadlock the composer just as the
    /// fork did.
    @Test func submittingNothingLeavesTheSessionWaitingOnTheUser() {
        let session = session()
        session.submit(blocks: [])
        #expect(!session.hasUserSubmitted)
    }
}
