import Testing
import Foundation
@testable import Plume

/// Deriving a subagent's live status from its own transcript.
///
/// Done is `stop_reason: end_turn` and nothing else, because a subagent
/// narrates between tool calls — trailing prose looks like a report but
/// usually is not one.
struct SubagentStatusTests {
    private func transcript(_ lines: [String]) -> Transcript {
        TranscriptParser.parse(Data(lines.joined(separator: "\n").utf8), includeSidechain: true)
    }

    /// `stop_reason` rides the line that closes an API response, so most
    /// lines omit it entirely.
    private func assistantText(_ text: String, stopReason: String? = nil) -> String {
        let stop = stopReason.map { #","stop_reason":"\#($0)""# } ?? ""
        return #"{"type":"assistant","uuid":"\#(UUID().uuidString)","isSidechain":true,"message":{"role":"assistant"\#(stop),"content":[{"type":"text","text":"\#(text)"}]}}"#
    }

    private func toolUse(id: String, name: String, stopReason: String? = nil) -> String {
        let stop = stopReason.map { #","stop_reason":"\#($0)""# } ?? ""
        return #"{"type":"assistant","uuid":"\#(UUID().uuidString)","isSidechain":true,"message":{"role":"assistant"\#(stop),"content":[{"type":"tool_use","id":"\#(id)","name":"\#(name)","input":{}}]}}"#
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

    @Test func aClosedTurnIsTheReport() {
        let status = SubagentStatusDeriver.derive(
            transcript: transcript([assistantText("Here is the report.", stopReason: "end_turn")]),
            parentResult: nil
        )

        #expect(status == .done)
    }

    /// The shape behind the false green checks: an agent narrating between
    /// tool calls ends its file on prose while still working. 49 of 210
    /// transcripts in a sampled corpus looked like this.
    @Test func trailingProseBetweenToolCallsIsStillWorking() {
        let status = SubagentStatusDeriver.derive(
            transcript: transcript([
                toolUse(id: "t1", name: "Bash", stopReason: "tool_use"),
                toolResult(id: "t1", content: "ok"),
                assistantText("All 538 tests passed. Now let me check the other suite."),
            ]),
            parentResult: nil
        )

        #expect(status == .working)
    }

    /// An async spawn's result arrives the instant the agent launches, so it
    /// must not be read as completion. 88% of spawns take this path.
    @Test func aLaunchAcknowledgementDoesNotMeanDone() {
        let status = SubagentStatusDeriver.derive(
            transcript: transcript([assistantText("starting"), toolUse(id: "t1", name: "Bash")]),
            parentResult: "Async agent launched successfully.\nagentId: a1"
        )

        #expect(status == .working)
    }

    /// A background agent whose file still ends on prose stays working even
    /// once its launch was acknowledged — the ack says nothing about the end.
    @Test func aBackgroundAgentWithTrailingProseIsWorking() {
        let status = SubagentStatusDeriver.derive(
            transcript: transcript([
                toolUse(id: "t1", name: "Grep", stopReason: "tool_use"),
                toolResult(id: "t1", content: "hits"),
                assistantText("Found the call sites."),
            ]),
            parentResult: "Async agent launched successfully.\nagentId: a1"
        )

        #expect(status == .working)
    }

    /// A synchronous spawn's real report completes an agent whose own file
    /// never recorded a closing turn.
    @Test func arealParentResultCompletesTheSubagent() {
        let status = SubagentStatusDeriver.derive(
            transcript: transcript([toolUse(id: "t1", name: "Bash"), toolResult(id: "t1", content: "ok")]),
            parentResult: "Here is what the agent found."
        )

        #expect(status == .done)
    }

    /// A resumed agent works past the turn it already closed, so the newest
    /// `stop_reason` wins over both the older one and the parent's report.
    @Test func workAfterAClosedTurnIsWorkingAgain() {
        let status = SubagentStatusDeriver.derive(
            transcript: transcript([
                assistantText("First answer.", stopReason: "end_turn"),
                toolUse(id: "t2", name: "Bash", stopReason: "tool_use"),
            ]),
            parentResult: "Here is what the agent found."
        )

        #expect(status == .working)
    }

    @Test func anErroredParentResultIsAFailure() {
        let status = SubagentStatusDeriver.derive(
            transcript: transcript([assistantText("Here is the report.", stopReason: "end_turn")]),
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

    /// A question outranks a closed turn: the model stops speaking to wait.
    @Test func anUnansweredQuestionIsWaitingForInput() {
        let status = SubagentStatusDeriver.derive(
            transcript: transcript([toolUse(id: "t1", name: "AskUserQuestion", stopReason: "end_turn")]),
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

    @Test func theParserKeepsTheNewestStopReason() {
        let parsed = transcript([
            assistantText("first", stopReason: "end_turn"),
            toolUse(id: "t1", name: "Bash", stopReason: "tool_use"),
        ])

        #expect(parsed.lastStopReason == "tool_use")
    }
}
