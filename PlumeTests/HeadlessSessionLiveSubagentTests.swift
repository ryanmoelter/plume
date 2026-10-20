import Foundation
import Testing
@testable import Plume

/// A turn that launches a background subagent ends with its `result` before
/// the transcript scan has seen the subagent, so the live task list is what
/// keeps that turn's end from announcing "It's your turn." The list drops the
/// subagent about a tenth of a second before the turn it wakes starts, and
/// that gap must not announce it either.
///
/// Line shapes come from a recorded `claude -p` 2.1.296 run.
@MainActor
struct HeadlessSessionLiveSubagentTests {
    private final class Recorder {
        var statuses: [TaskStatus] = []
    }

    private func makeSession() -> (HeadlessSession, StatusEngine, Recorder) {
        let engine = StatusEngine(backgroundTasks: BackgroundTaskTracker())
        let session = HeadlessSession(tabID: UUID(), taskID: UUID(), statusEngine: engine)
        engine.register(tabID: session.tabID, taskID: session.taskID)
        let recorder = Recorder()
        engine.setTabStatusObserver("test") { _, _, status, _ in recorder.statuses.append(status) }
        return (session, engine, recorder)
    }

    private func decode(_ line: String) throws -> StreamJSONMessage {
        try #require(StreamJSONDecoder.decode(line: line))
    }

    private static let agentListed = #"{"type":"system","subtype":"background_tasks_changed","tasks":[{"task_id":"ad44f8d744bd65948","run_id":"0mvahr3xf-91aa5ed5","task_type":"local_agent","subagent_type":"general-purpose","description":"Sleep 15 seconds"}]}"#
    private static let listEmptied = #"{"type":"system","subtype":"background_tasks_changed","tasks":[]}"#
    private static let mainAssistant = #"{"type":"assistant","parent_tool_use_id":null,"message":{"role":"assistant","content":[{"type":"text","text":"OK"}]}}"#
    private static let result = #"{"type":"result","subtype":"success","is_error":false,"result":"OK"}"#
    private static let requesting = #"{"type":"system","subtype":"status","status":"requesting"}"#

    private func launchBackgroundAgentAndEndTurn(_ session: HeadlessSession) throws {
        session.handle(try decode(Self.mainAssistant))
        session.handle(try decode(Self.agentListed))
        session.handle(try decode(Self.result))
    }

    @Test func aTurnEndingWithAListedSubagentDoesNotAnnounceItsEnd() throws {
        let (session, engine, recorder) = makeSession()

        try launchBackgroundAgentAndEndTurn(session)

        #expect(engine.status(forTab: session.tabID) == .waitingOnSubagents)
        #expect(!recorder.statuses.contains(.awaitingReply))
    }

    @Test func theWokenTurnFollowsWithoutAnAnnouncedEnd() throws {
        let (session, engine, recorder) = makeSession()
        try launchBackgroundAgentAndEndTurn(session)

        session.handle(try decode(Self.listEmptied))
        #expect(engine.status(forTab: session.tabID) == .waitingOnSubagents)
        session.handle(try decode(Self.requesting))
        session.handle(try decode(Self.mainAssistant))
        session.handle(try decode(Self.result))

        #expect(recorder.statuses == [.working, .waitingOnSubagents, .working, .awaitingReply])
    }

    @Test func aDropWithNoWokenTurnSettlesAfterTheGrace() async throws {
        let (session, engine, recorder) = makeSession()
        session.subagentWakeGrace = .milliseconds(10)
        try launchBackgroundAgentAndEndTurn(session)

        session.handle(try decode(Self.listEmptied))
        var polls = 0
        while engine.status(forTab: session.tabID) != .awaitingReply, polls < 500 {
            try await Task.sleep(for: .milliseconds(10))
            polls += 1
        }

        #expect(engine.status(forTab: session.tabID) == .awaitingReply)
        #expect(recorder.statuses.last == .awaitingReply)
    }

    @Test func aDropMidTurnClearsAtOnce() throws {
        let (session, engine, _) = makeSession()
        session.handle(try decode(Self.mainAssistant))
        session.handle(try decode(Self.agentListed))

        session.handle(try decode(Self.listEmptied))

        #expect(!engine.hasLiveSubagents(tabID: session.tabID))
    }

    @Test func stoppingTheSessionClearsListedSubagents() throws {
        let (session, engine, _) = makeSession()
        try launchBackgroundAgentAndEndTurn(session)

        session.stop()

        #expect(!engine.hasWorkingSubagents(tabID: session.tabID))
    }

    @Test func onlyAgentTaskTypesAreSubagents() {
        #expect(LiveBackgroundTask(id: "a", taskType: "local_agent", description: nil).isSubagent)
        #expect(LiveBackgroundTask(id: "a", taskType: "remote_agent", description: nil).isSubagent)
        #expect(!LiveBackgroundTask(id: "a", taskType: "local_bash", description: nil).isSubagent)
        #expect(!LiveBackgroundTask(id: "a", taskType: "local_workflow", description: nil).isSubagent)
    }
}
