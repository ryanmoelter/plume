import Testing
import Foundation
@testable import Plume

/// Deriving a subagent's live status from its own transcript and whatever the
/// parent recorded about it.
///
/// Done is `stop_reason: end_turn` in the subagent's file, or a real
/// completion for it in the parent. Trailing prose is neither, because a
/// subagent narrates between tool calls — it looks like a report but usually
/// is not one.
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

    /// Escape mid-turn writes exactly this line, in every one of the five
    /// interrupted transcripts in the sampled corpus.
    private func interruption() -> String {
        #"{"type":"user","uuid":"\#(UUID().uuidString)","isSidechain":true,"message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]}}"#
    }

    @Test func anEmptyTranscriptHasNoStatus() {
        #expect(SubagentStatusDeriver.derive(transcript: Transcript(), parentSignal: nil) == .notStarted)
    }

    /// A tool call with no result yet is the agent mid-step.
    @Test func aTrailingUnansweredToolCallIsWorking() {
        let status = SubagentStatusDeriver.derive(
            transcript: transcript([assistantText("checking"), toolUse(id: "t1", name: "Bash")]),
            parentSignal: nil
        )

        #expect(status == .working)
    }

    @Test func aClosedTurnIsTheReport() {
        let status = SubagentStatusDeriver.derive(
            transcript: transcript([assistantText("Here is the report.", stopReason: "end_turn")]),
            parentSignal: nil
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
            parentSignal: nil
        )

        #expect(status == .working)
    }

    /// An async spawn's result arrives the instant the agent launches, so it
    /// must not be read as completion. 88% of spawns take this path.
    @Test func aLaunchAcknowledgementDoesNotMeanDone() {
        let status = SubagentStatusDeriver.derive(
            transcript: transcript([assistantText("starting"), toolUse(id: "t1", name: "Bash")]),
            parentSignal: .launched
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
            parentSignal: .launched
        )

        #expect(status == .working)
    }

    /// A synchronous spawn's real report completes an agent whose own file
    /// never recorded a closing turn.
    @Test func arealParentResultCompletesTheSubagent() {
        let status = SubagentStatusDeriver.derive(
            transcript: transcript([toolUse(id: "t1", name: "Bash"), toolResult(id: "t1", content: "ok")]),
            parentSignal: .completed
        )

        #expect(status == .done)
    }

    /// A resumed agent works past the turn it already closed, so the newest
    /// `stop_reason` wins over the older one.
    @Test func workAfterAClosedTurnIsWorkingAgain() {
        let status = SubagentStatusDeriver.derive(
            transcript: transcript([
                assistantText("First answer.", stopReason: "end_turn"),
                toolUse(id: "t2", name: "Bash", stopReason: "tool_use"),
            ]),
            parentSignal: .launched
        )

        #expect(status == .working)
    }

    /// The user killed it mid-step, so the file keeps the `tool_use` stop
    /// reason of the step it was on and would otherwise spin forever.
    @Test func anInterruptionInTheTailIsInterrupted() {
        let lines = [
            toolUse(id: "t1", name: "Bash", stopReason: "tool_use"),
            toolResult(id: "t1", content: "ok"),
            interruption(),
        ]

        #expect(SubagentStatusDeriver.derive(transcript: transcript(lines), parentSignal: nil) == .interrupted)
        #expect(SubagentStatusDeriver.derive(transcript: transcript(lines), parentSignal: .launched) == .interrupted)
    }

    /// An interrupted agent told to carry on finishes normally, so only an
    /// interruption in the last message counts.
    @Test func anInterruptionTheAgentWorkedPastIsNotInterrupted() {
        let status = SubagentStatusDeriver.derive(
            transcript: transcript([
                toolUse(id: "t1", name: "Bash", stopReason: "tool_use"),
                interruption(),
                assistantText("Picking it back up.", stopReason: "end_turn"),
            ]),
            parentSignal: nil
        )

        #expect(status == .done)
    }

    /// Interruption is checked last, so it can only ever replace `working`.
    @Test func aParentCompletionOutranksATrailingInterruption() {
        let status = SubagentStatusDeriver.derive(
            transcript: transcript([toolUse(id: "t1", name: "Bash", stopReason: "tool_use"), interruption()]),
            parentSignal: .completed
        )

        #expect(status == .done)
    }

    @Test func aFailedSpawnOutranksATrailingInterruption() {
        let status = SubagentStatusDeriver.derive(
            transcript: transcript([toolUse(id: "t1", name: "Bash", stopReason: "tool_use"), interruption()]),
            parentSignal: .failed
        )

        #expect(status == .error)
    }

    @Test func anErroredParentResultIsAFailure() {
        let status = SubagentStatusDeriver.derive(
            transcript: transcript([assistantText("Here is the report.", stopReason: "end_turn")]),
            parentSignal: .completed,
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
            parentSignal: nil
        )

        #expect(status == .error)
    }

    /// A question outranks a closed turn: the model stops speaking to wait.
    @Test func anUnansweredQuestionSaysItAskedOne() {
        let status = SubagentStatusDeriver.derive(
            transcript: transcript([toolUse(id: "t1", name: "AskUserQuestion", stopReason: "end_turn")]),
            parentSignal: nil
        )

        #expect(status == .questionAsked)
    }

    @Test func anUnansweredPlanProposalSaysItWantsApproval() {
        let status = SubagentStatusDeriver.derive(
            transcript: transcript([toolUse(id: "t1", name: "ExitPlanMode")]),
            parentSignal: nil
        )

        #expect(status == .planApproval)
    }

    /// Once the question is answered the agent is running again.
    @Test func anansweredQuestionIsNoLongerWaiting() {
        let status = SubagentStatusDeriver.derive(
            transcript: transcript([
                toolUse(id: "t1", name: "AskUserQuestion"),
                toolResult(id: "t1", content: "the answer"),
                toolUse(id: "t2", name: "Bash"),
            ]),
            parentSignal: nil
        )

        #expect(status == .working)
    }

    /// The live bug, and the most common mismatch in the corpus: the agent's
    /// closing message is written while streaming and carries a null
    /// `stop_reason`, so the newest value the parser keeps is the `tool_use`
    /// from the turn before and the row stays working forever. The parent
    /// meanwhile holds the agent's whole report. 17 of 510 sampled agents.
    @Test func aStreamedClosingMessageIsDoneWhenTheParentHasTheReport() {
        let lines = [
            toolUse(id: "t1", name: "Bash", stopReason: "tool_use"),
            toolResult(id: "t1", content: "ok"),
            #"{"type":"assistant","uuid":"a9","isSidechain":true,"message":{"role":"assistant","stop_reason":null,"content":[{"type":"text","text":"Confirmed: nothing references it yet."}]}}"#,
        ]

        #expect(transcript(lines).lastStopReason == "tool_use")
        #expect(SubagentStatusDeriver.derive(transcript: transcript(lines), parentSignal: nil) == .working)
        #expect(SubagentStatusDeriver.derive(transcript: transcript(lines), parentSignal: .completed) == .done)
    }

    /// An agent cut off mid-response closes on `stop_sequence`, which is not
    /// `end_turn` — but the parent still recorded a report. 2 of 510.
    @Test func aTurnEndingOnStopSequenceIsDoneWhenTheParentHasTheReport() {
        let lines = [
            assistantText("Resuming the dispatch."),
            assistantText("API Error: Connection closed mid-response.", stopReason: "stop_sequence"),
        ]

        #expect(SubagentStatusDeriver.derive(transcript: transcript(lines), parentSignal: nil) == .working)
        #expect(SubagentStatusDeriver.derive(transcript: transcript(lines), parentSignal: .completed) == .done)
    }

    /// A background agent's completion never touches the spawning call, so a
    /// `task_status` attachment in the parent is the only record of it.
    @Test func aTaskNotificationCompletesABackgroundAgent() {
        let parent = Data(#"{"type":"attachment","uuid":"p1","attachment":{"type":"task_status","taskId":"a1","taskType":"local_agent","status":"completed"}}"#.utf8)

        #expect(SubagentSpawnResults(parentData: parent).signal(forAgentID: "a1") == .completed)
    }

    @Test func aCompletedSpawnResultIsAParentCompletion() {
        let parent = Data(#"{"type":"user","uuid":"p1","toolUseResult":{"status":"completed","agentId":"a1","content":"the report"}}"#.utf8)

        #expect(SubagentSpawnResults(parentData: parent).signal(forAgentID: "a1") == .completed)
    }

    /// The status is read rather than the result text, so the launch ack needs
    /// no English match.
    @Test func anAsyncLaunchIsOnlyALaunch() {
        let parent = Data(#"{"type":"user","uuid":"p1","toolUseResult":{"status":"async_launched","isAsync":true,"agentId":"a1"}}"#.utf8)

        #expect(SubagentSpawnResults(parentData: parent).signal(forAgentID: "a1") == .launched)
    }

    /// An async agent's launch is recorded first and its report later, so the
    /// earlier record must not win.
    @Test func aLaterCompletionOutranksTheLaunchThatPrecededIt() {
        let parent = Data([
            #"{"type":"user","uuid":"p1","toolUseResult":{"status":"async_launched","agentId":"a1"}}"#,
            #"{"type":"attachment","uuid":"p2","attachment":{"type":"task_status","taskId":"a1","status":"completed"}}"#,
        ].joined(separator: "\n").utf8)

        #expect(SubagentSpawnResults(parentData: parent).signal(forAgentID: "a1") == .completed)
    }

    /// A `toolUseResult` is sometimes a bare string rather than an object, and
    /// a line like that must not take the whole parent scan down with it.
    @Test func aStringSpawnResultIsIgnoredRatherThanFatal() {
        let parent = Data([
            #"{"type":"user","uuid":"p1","toolUseResult":"the agent crashed"}"#,
            #"{"type":"user","uuid":"p2","toolUseResult":{"status":"completed","agentId":"a1"}}"#,
        ].joined(separator: "\n").utf8)

        let results = SubagentSpawnResults(parentData: parent)

        #expect(results.signal(forAgentID: "a1") == .completed)
        #expect(results.signal(forAgentID: "missing") == nil)
    }

    @Test func theParserKeepsTheNewestStopReason() {
        let parsed = transcript([
            assistantText("first", stopReason: "end_turn"),
            toolUse(id: "t1", name: "Bash", stopReason: "tool_use"),
        ])

        #expect(parsed.lastStopReason == "tool_use")
    }

    /// A subagent killed mid-tool-call writes no marker of its own: its file
    /// ends on the unanswered call or on an attachment, carrying
    /// `stop_reason: tool_use`, so every transcript signal reads as working.
    /// The parent's `killed`/`stopped` notification is the only record that
    /// it has ended.
    @Test func anAgentTheParentReportsStoppedIsInterrupted() {
        let status = SubagentStatusDeriver.derive(
            transcript: transcript([assistantText("building"), toolUse(id: "t1", name: "Bash")]),
            parentSignal: .stopped
        )

        #expect(status == .interrupted)
    }

    /// The guard that matters: a stop must never outrank the agent's own
    /// report, so one resumed after a stop still reads as done.
    @Test func aStopDoesNotOverrideTheAgentsOwnEndTurn() {
        let status = SubagentStatusDeriver.derive(
            transcript: transcript([assistantText("Here is the report.", stopReason: "end_turn")]),
            parentSignal: .stopped
        )

        #expect(status == .done)
    }

    /// A stopped agent left holding an unanswered question is still waiting on
    /// a person, which is the more actionable thing to say about it.
    @Test func aStopDoesNotOverrideAWaitingPrompt() {
        let status = SubagentStatusDeriver.derive(
            transcript: transcript([toolUse(id: "t1", name: "AskUserQuestion")]),
            parentSignal: .stopped
        )

        #expect(status == .questionAsked)
    }

    /// Nothing about a stop implies failure, and an errored agent is reported
    /// by its own notice.
    @Test func aStopIsNotAnError() {
        let status = SubagentStatusDeriver.derive(
            transcript: transcript([assistantText("working"), toolUse(id: "t1", name: "Bash")]),
            parentSignal: .stopped
        )

        #expect(status != .error)
    }
}
