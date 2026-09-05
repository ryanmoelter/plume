import Testing
import Foundation
@testable import Plume

/// Deriving a subagent's live status from its own transcript tail plus the
/// parent's matching tool_result.
struct SubagentStatusTests {
    private func transcript(_ lines: [String]) -> Transcript {
        TranscriptParser.parse(Data(lines.joined(separator: "\n").utf8), includeSidechain: true)
    }

    private func assistantText(_ text: String) -> String {
        #"{"type":"assistant","uuid":"\#(UUID().uuidString)","isSidechain":true,"message":{"role":"assistant","content":[{"type":"text","text":"\#(text)"}]}}"#
    }

    private func toolUse(id: String, name: String) -> String {
        #"{"type":"assistant","uuid":"\#(UUID().uuidString)","isSidechain":true,"message":{"role":"assistant","content":[{"type":"tool_use","id":"\#(id)","name":"\#(name)","input":{}}]}}"#
    }

    private func toolResult(id: String, content: String) -> String {
        #"{"type":"user","uuid":"\#(UUID().uuidString)","isSidechain":true,"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"\#(id)","content":"\#(content)"}]}}"#
    }

    @Test func anEmptyTranscriptHasNoStatus() {
        #expect(SubagentStatusDeriver.derive(transcript: Transcript(), parentResult: nil) == .unset)
    }

    /// A tool call with no result yet is the agent mid-step.
    @Test func aTrailingUnansweredToolCallIsWorking() {
        let status = SubagentStatusDeriver.derive(
            transcript: transcript([assistantText("checking"), toolUse(id: "t1", name: "Bash")]),
            parentResult: nil
        )

        #expect(status == .working)
    }

    @Test func trailingProseReadsAsTheAgentsReport() {
        let status = SubagentStatusDeriver.derive(
            transcript: transcript([assistantText("Here is the report.")]),
            parentResult: nil
        )

        #expect(status == .done)
    }

    /// An async spawn's result arrives the instant the agent launches, so it
    /// must not be read as completion.
    @Test func aLaunchAcknowledgementDoesNotMeanDone() {
        let status = SubagentStatusDeriver.derive(
            transcript: transcript([assistantText("starting"), toolUse(id: "t1", name: "Bash")]),
            parentResult: "Async agent launched successfully.\nagentId: a1"
        )

        #expect(status == .working)
    }

    /// A real result for the spawning call is the completion signal, even
    /// where the subagent's own tail looks mid-step.
    @Test func arealParentResultCompletesTheSubagent() {
        let status = SubagentStatusDeriver.derive(
            transcript: transcript([toolUse(id: "t1", name: "Bash"), toolResult(id: "t1", content: "ok")]),
            parentResult: "Here is what the agent found."
        )

        #expect(status == .done)
    }

    @Test func anErroredParentResultIsAFailure() {
        let status = SubagentStatusDeriver.derive(
            transcript: transcript([assistantText("Here is the report.")]),
            parentResult: "the agent crashed",
            parentResultIsError: true
        )

        #expect(status == .error)
    }

    @Test func anApiErrorNoticeInTheTailIsAFailure() {
        let status = SubagentStatusDeriver.derive(
            transcript: transcript([
                assistantText("working"),
                #"{"type":"system","uuid":"s1","isSidechain":true,"subtype":"api_error","error":{"status":500,"message":"overloaded"}}"#,
            ]),
            parentResult: nil
        )

        #expect(status == .error)
    }

    @Test func anUnansweredQuestionIsWaitingForInput() {
        let status = SubagentStatusDeriver.derive(
            transcript: transcript([toolUse(id: "t1", name: "AskUserQuestion")]),
            parentResult: nil
        )

        #expect(status == .needsInput)
    }

    @Test func anUnansweredPlanProposalIsWaitingForInput() {
        let status = SubagentStatusDeriver.derive(
            transcript: transcript([toolUse(id: "t1", name: "ExitPlanMode")]),
            parentResult: nil
        )

        #expect(status == .needsInput)
    }

    /// Once the question is answered the agent is running again.
    @Test func anansweredQuestionIsNoLongerWaiting() {
        let status = SubagentStatusDeriver.derive(
            transcript: transcript([
                toolUse(id: "t1", name: "AskUserQuestion"),
                toolResult(id: "t1", content: "the answer"),
                toolUse(id: "t2", name: "Bash"),
            ]),
            parentResult: nil
        )

        #expect(status == .working)
    }
}
