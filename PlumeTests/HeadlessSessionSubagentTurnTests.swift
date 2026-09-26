import Foundation
import Testing
@testable import Plume

/// A background subagent keeps streaming envelopes, tagged with its spawning
/// call's `parent_tool_use_id`, after the main agent's turn has ended. No
/// `result` follows them, so none of them may start a main turn: a turn begun
/// there would hold the tab at `working` and queue every message the user
/// sends until the next main turn happened to end.
///
/// The line shapes come from a recorded `claude -p` 2.1.280 run.
@MainActor
struct HeadlessSessionSubagentTurnTests {
    private func makeSession() -> (HeadlessSession, StatusEngine) {
        let engine = StatusEngine(backgroundTasks: BackgroundTaskTracker())
        let session = HeadlessSession(tabID: UUID(), taskID: UUID(), statusEngine: engine)
        engine.register(tabID: session.tabID, taskID: session.taskID)
        return (session, engine)
    }

    private func decode(_ line: String) throws -> StreamJSONMessage {
        try #require(StreamJSONDecoder.decode(line: line))
    }

    private func mainAssistant() throws -> StreamJSONMessage {
        try decode(#"{"type":"assistant","parent_tool_use_id":null,"message":{"role":"assistant","content":[{"type":"text","text":"launched"}]}}"#)
    }

    private func subagentAssistant() throws -> StreamJSONMessage {
        try decode(#"{"type":"assistant","parent_tool_use_id":"toolu_01Nb7YK9BPcoxERhZX5rAWp6","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_x","name":"Bash","input":{"command":"sleep 30"}}]}}"#)
    }

    private func subagentInterrupted() throws -> StreamJSONMessage {
        try decode(#"{"type":"user","parent_tool_use_id":"toolu_01Nb7YK9BPcoxERhZX5rAWp6","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]}}"#)
    }

    private func result() throws -> StreamJSONMessage {
        try decode(#"{"type":"result","subtype":"success","is_error":false,"result":"launched"}"#)
    }

    private func endMainTurn(_ session: HeadlessSession) throws {
        session.handle(try mainAssistant())
        session.handle(try result())
    }

    @Test func aSubagentEnvelopeBetweenTurnsStartsNoTurn() throws {
        let (session, engine) = makeSession()
        try endMainTurn(session)

        session.handle(try subagentAssistant())

        #expect(!session.isWorking)
        #expect(engine.ownStatus(forTab: session.tabID) == .awaitingReply)
    }

    @Test func theTabWaitsWhileOnlySubagentsWork() throws {
        let (session, engine) = makeSession()
        try endMainTurn(session)
        engine.setSubagentActivity(tabID: session.tabID, working: true)

        session.handle(try subagentAssistant())

        #expect(!session.isWorking)
        #expect(session.hasWorkingSubagents)
        #expect(engine.status(forTab: session.tabID) == .waitingOnSubagents)
    }

    /// Stopping a background subagent between turns answers the interrupt
    /// with no `result`, so a turn opened by the subagent's envelopes could
    /// never close.
    @Test func stoppingASubagentBetweenTurnsLeavesTheTabSettled() throws {
        let (session, engine) = makeSession()
        try endMainTurn(session)
        engine.setSubagentActivity(tabID: session.tabID, working: true)
        session.handle(try subagentAssistant())

        session.interrupt()
        session.handle(try subagentInterrupted())
        engine.setSubagentActivity(tabID: session.tabID, working: false)

        #expect(!session.isWorking)
        #expect(engine.status(forTab: session.tabID) == .awaitingReply)
    }

    /// A task notification still wakes the main agent, and its envelopes
    /// carry no parent.
    @Test func theMainAgentsOwnEnvelopeStillStartsATurn() throws {
        let (session, engine) = makeSession()
        try endMainTurn(session)
        engine.setSubagentActivity(tabID: session.tabID, working: true)

        session.handle(try mainAssistant())

        #expect(session.isWorking)
        #expect(engine.status(forTab: session.tabID) == .working)
    }
}
