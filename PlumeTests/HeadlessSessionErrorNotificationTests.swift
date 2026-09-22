import Foundation
import Testing
@testable import Plume

/// A tab resumes the moment it becomes visible, with no message behind it, so
/// every launch would otherwise announce "The agent stopped unexpectedly" for
/// a resume that failed a turn the user never started. The tab still reads
/// `error` either way — only the notification is withheld.
@MainActor
struct HeadlessSessionErrorNotificationTests {
    /// Hooks the callback `StatusNotifier` hooks, so what this records is
    /// exactly what would have been notified.
    private final class Recorder {
        var reported: [(status: TaskStatus, notifiable: Bool)] = []

        var notifiableErrors: Int {
            reported.count { $0.status == .error && $0.notifiable }
        }

        var sawError: Bool {
            reported.contains { $0.status == .error }
        }
    }

    private func makeSession() -> (HeadlessSession, Recorder) {
        let engine = StatusEngine()
        let recorder = Recorder()
        engine.onTabStatusChanged = { _, _, status, notifiable in
            recorder.reported.append((status, notifiable))
        }
        let session = HeadlessSession(tabID: UUID(), taskID: UUID(), statusEngine: engine)
        return (session, recorder)
    }

    @Test func aPreflightFailureBeforeAnyMessageDoesNotNotify() {
        let (session, recorder) = makeSession()
        session.failToLaunch(reason: "claude: command not found")

        #expect(recorder.sawError)
        #expect(recorder.notifiableErrors == 0)
    }

    @Test func aPreflightFailureAfterTheUserWroteNotifies() {
        let (session, recorder) = makeSession()
        // No process is running, so the text is queued rather than sent. The
        // user asking for the turn is what matters, not whether it left.
        session.submit(text: "go")
        session.failToLaunch(reason: "claude: command not found")

        #expect(recorder.notifiableErrors == 1)
    }
}
