import Foundation
import Testing
@testable import Plume

/// A closed tab's session can still hear from its process: the exit and any
/// line already in flight arrive after `TaskStore.forgetTab` cleared the tab.
/// Reporting them would re-register the deleted tab, and a stray `error` on it
/// would hold the task's sidebar badge for as long as the app runs.
@MainActor
struct HeadlessSessionClosedStatusTests {
    private func makeSession() -> (HeadlessSession, StatusEngine) {
        let engine = StatusEngine(backgroundTasks: BackgroundTaskTracker())
        let session = HeadlessSession(tabID: UUID(), taskID: UUID(), statusEngine: engine)
        engine.register(tabID: session.tabID, taskID: session.taskID)
        return (session, engine)
    }

    private func closeTab(_ session: HeadlessSession, in engine: StatusEngine) {
        engine.forget(tabID: session.tabID, taskID: session.taskID)
        session.stop()
    }

    @Test func aLateErrorResultDoesNotResurrectAClosedTab() throws {
        let (session, engine) = makeSession()
        closeTab(session, in: engine)

        session.handle(try #require(StreamJSONDecoder.decode(
            line: #"{"type":"result","subtype":"error_during_execution","is_error":true}"#
        )))

        #expect(engine.taskID(forTab: session.tabID) == nil)
        #expect(engine.status(forTask: session.taskID) == .notStarted)
    }

    @Test func aLateLaunchFailureDoesNotResurrectAClosedTab() {
        let (session, engine) = makeSession()
        closeTab(session, in: engine)

        session.failToLaunch(reason: "claude: command not found")

        #expect(engine.taskID(forTab: session.tabID) == nil)
    }
}
