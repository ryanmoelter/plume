import Foundation
import Testing
@testable import Plume

/// `startFailure` is what the chat shows in place of a conversation that
/// never began, so it has to stay silent for a session that is merely idle or
/// was stopped on purpose.
@MainActor
struct HeadlessSessionStartFailureTests {
    private func makeSession() -> HeadlessSession {
        HeadlessSession(tabID: UUID(), taskID: UUID())
    }

    @Test func aSessionThatNeverRanReportsNothing() {
        #expect(makeSession().startFailure == nil)
    }

    /// `stop()` exits without an error, so a session the user closed must not
    /// read as a failed start.
    @Test func aStoppedSessionReportsNothing() {
        let session = makeSession()
        session.stop()

        #expect(session.hasExited)
        #expect(session.startFailure == nil)
    }

    @Test func aFailedPreflightReportsItsReason() throws {
        let session = makeSession()
        session.failToLaunch(reason: "claude: command not found")

        let failure = try #require(session.startFailure)
        #expect(failure.remedy == .installCLI)
        #expect(failure.detail == "claude: command not found")
    }
}
