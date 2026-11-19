import Foundation
import Testing
@testable import Plume

/// A session tracks the newest main-thread user row a fork can cut at: the
/// prompt its turn answers, or a tool result that leaves no tool call open.
/// Line shapes come from probing `claude -p` 2.1.321.
@MainActor
struct ForkCutPointTests {
    private func makeSession() -> HeadlessSession {
        let engine = StatusEngine(backgroundTasks: BackgroundTaskTracker())
        let session = HeadlessSession(tabID: UUID(), taskID: UUID(), statusEngine: engine)
        engine.register(tabID: session.tabID, taskID: session.taskID)
        session.debugLineSink = { _ in }
        return session
    }

    private func receive(_ session: HeadlessSession, _ lines: String...) throws {
        for line in lines { session.handle(try #require(StreamJSONDecoder.decode(line: line))) }
    }

    private static func thinking(prompt: String) -> String {
        #"{"type":"assistant","uuid":"a-think","user_message_uuid":"\#(prompt)","parent_tool_use_id":null,"message":{"id":"msg_1","role":"assistant","content":[{"type":"thinking","thinking":""}]}}"#
    }

    private static func toolUse(_ ids: String..., subagent: String? = nil) -> String {
        let blocks = ids.map { #"{"type":"tool_use","id":"\#($0)","name":"Bash","input":{}}"# }.joined(separator: ",")
        let parent = subagent.map { #""\#($0)""# } ?? "null"
        return #"{"type":"assistant","uuid":"a-\#(ids.joined())","parent_tool_use_id":\#(parent),"message":{"id":"msg_1","role":"assistant","content":[\#(blocks)]}}"#
    }

    private static func toolResult(_ id: String, uuid: String, subagent: String? = nil) -> String {
        let parent = subagent.map { #""\#($0)""# } ?? "null"
        return #"{"type":"user","uuid":"\#(uuid)","parent_tool_use_id":\#(parent),"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"\#(id)","content":"hi"}]}}"#
    }

    private static let result = #"{"type":"result","subtype":"success","is_error":false,"result":"DONE"}"#

    @Test func aTurnsPromptIsTheFirstCut() throws {
        let session = makeSession()
        #expect(session.latestForkCut == nil)
        try receive(session, Self.thinking(prompt: "prompt-1"))
        #expect(session.latestForkCut == "prompt-1")
    }

    @Test func aToolResultMovesTheCutButAnOpenCallHoldsIt() throws {
        let session = makeSession()
        try receive(session, Self.thinking(prompt: "prompt-1"), Self.toolUse("t1"), Self.toolResult("t1", uuid: "result-1"))
        #expect(session.latestForkCut == "result-1")

        try receive(session, Self.toolUse("t2"))
        #expect(session.latestForkCut == "result-1")
    }

    @Test func parallelCallsMoveTheCutOnlyOnceAllHaveAnswered() throws {
        let session = makeSession()
        try receive(session, Self.thinking(prompt: "prompt-1"), Self.toolUse("t1", "t2"), Self.toolResult("t1", uuid: "result-1"))
        #expect(session.latestForkCut == "prompt-1")

        try receive(session, Self.toolResult("t2", uuid: "result-2"))
        #expect(session.latestForkCut == "result-2")
    }

    @Test func aSubagentsRowsAreIgnored() throws {
        let session = makeSession()
        try receive(
            session,
            Self.thinking(prompt: "prompt-1"),
            Self.toolUse("agent"),
            Self.toolUse("inner", subagent: "agent"),
            Self.toolResult("inner", uuid: "inner-result", subagent: "agent")
        )
        #expect(session.latestForkCut == "prompt-1")
    }

    @Test func aCallLeftOpenAtTheTurnsEndDoesNotHoldTheNextTurn() throws {
        let session = makeSession()
        try receive(session, Self.thinking(prompt: "prompt-1"), Self.toolUse("t1"), Self.result)
        try receive(session, Self.thinking(prompt: "prompt-2"))
        #expect(session.latestForkCut == "prompt-2")
    }
}
