import Testing
import Foundation
@testable import Plume

/// Reading a subagent's completion from the `<task-notification>` the CLI
/// enqueues, which is the signal current builds actually write.
///
/// The status is a word lifted out of a plain string, so every degenerate
/// shape here must yield *no* signal — never a wrong one.
struct SubagentTaskNotificationTests {
    private func notification(
        taskID: String = "a1",
        status: String? = "completed",
        result: String = "the report"
    ) -> String {
        let statusTag = status.map { "<status>\($0)</status>\n" } ?? ""
        return """
        <task-notification>
        <task-id>\(taskID)</task-id>
        <tool-use-id>toolu_1</tool-use-id>
        <output-file>/tmp/\(taskID).output</output-file>
        \(statusTag)<summary>Agent "Explore" finished</summary>
        <result>\(result)</result>
        </task-notification>
        """
    }

    private func queueLine(_ content: String, operation: String = "enqueue") -> String {
        let object: [String: Any] = ["type": "queue-operation", "operation": operation, "content": content]
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    private func results(_ lines: [String]) -> SubagentSpawnResults {
        SubagentSpawnResults(parentData: Data(lines.joined(separator: "\n").utf8))
    }

    @Test func aCompletedNotificationCompletesTheSubagent() {
        #expect(results([queueLine(notification())]).signal(forAgentID: "a1") == .completed)
    }

    @Test func aFailedNotificationIsAFailure() {
        #expect(results([queueLine(notification(status: "failed"))]).signal(forAgentID: "a1") == .failed)
    }

    /// The corpus's other two statuses. Neither says the agent reported, so
    /// they leave the verdict to the subagent's own transcript.
    @Test(arguments: ["killed", "stopped", "something-new"])
    func anEndingTheParentCannotVouchForIsNoSignal(status: String) {
        #expect(results([queueLine(notification(status: status))]).signal(forAgentID: "a1") == nil)
    }

    @Test func aNotificationWithNoStatusIsNoSignal() {
        #expect(results([queueLine(notification(status: nil))]).signal(forAgentID: "a1") == nil)
    }

    /// An agent's own report can quote the tags, so only the header counts.
    @Test func aStatusQuotedInTheResultBodyIsNotRead() {
        let line = queueLine(notification(
            status: "killed",
            result: "I wrote <status>completed</status> for <task-id>a2</task-id> in the docs"
        ))
        let parsed = results([line])

        #expect(parsed.signal(forAgentID: "a1") == nil)
        #expect(parsed.signal(forAgentID: "a2") == nil)
    }

    @Test func aQueueLineThatIsNotANotificationIsIgnored() {
        let lines = [
            #"{"type":"queue-operation","operation":"enqueue","timestamp":"2026-09-05T22:15:14.897Z"}"#,
            queueLine("just some queued prompt text"),
            queueLine("<task-notification>\n<status>completed</status>\n</task-notification>"),
        ]

        #expect(results(lines).signal(forAgentID: "a1") == nil)
    }

    /// The notification is a `queue-operation` line's payload. The same text
    /// arrives again as an ordinary user message, and reading it there would
    /// let a user quoting the block fabricate a completion.
    @Test func theSameTextInAUserMessageIsNotASignal() {
        let object: [String: Any] = [
            "type": "user",
            "uuid": "u1",
            "message": ["role": "user", "content": notification()],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()

        #expect(SubagentSpawnResults(parentData: data).signal(forAgentID: "a1") == nil)
    }

    @Test func aNotificationOutranksTheLaunchThatPrecededIt() {
        let lines = [
            #"{"type":"user","uuid":"p1","toolUseResult":{"status":"async_launched","agentId":"a1"}}"#,
            queueLine(notification()),
        ]

        #expect(results(lines).signal(forAgentID: "a1") == .completed)
    }

    @Test func theEntryExposesTheNotificationItCarries() {
        let data = Data(queueLine(notification(taskID: "abc", status: "completed")).utf8)
        let entry = try? JSONDecoder().decode(TranscriptEntry.self, from: data)

        #expect(entry?.operation == "enqueue")
        #expect(entry?.taskNotification == TranscriptTaskNotification(content: notification(
            taskID: "abc",
            status: "completed"
        )))
        #expect(entry?.taskNotification?.taskID == "abc")
        #expect(entry?.taskNotification?.status == "completed")
    }
}

/// A stopped agent is notified `completed` like any other, so the sidecar's
/// `stoppedByUser` is the only thing that keeps it out of `done`.
struct StoppedSubagentTests {
    private func transcript(_ lines: [String]) -> Transcript {
        TranscriptParser.parse(Data(lines.joined(separator: "\n").utf8), includeSidechain: true)
    }

    private var interruptedTail: [String] {
        [
            #"{"type":"assistant","uuid":"a1","isSidechain":true,"message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{}}]}}"#,
            #"{"type":"user","uuid":"u1","isSidechain":true,"message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]}}"#,
        ]
    }

    @Test func aStoppedAgentStaysInterruptedDespiteItsCompletion() {
        let parsed = transcript(interruptedTail)

        #expect(SubagentStatusDeriver.derive(transcript: parsed, parentSignal: .completed) == .done)
        #expect(
            SubagentStatusDeriver.derive(transcript: parsed, parentSignal: .completed, stoppedByUser: true)
                == .interrupted
        )
    }

    /// The flag suppresses only the parent's word. An agent resumed after a
    /// stop finishes normally, and its own `end_turn` still says so.
    @Test func aStoppedAgentThatWasResumedIsDoneAgain() {
        let parsed = transcript(interruptedTail + [
            #"{"type":"assistant","uuid":"a2","isSidechain":true,"message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"carried on"}]}}"#,
        ])

        #expect(
            SubagentStatusDeriver.derive(transcript: parsed, parentSignal: .completed, stoppedByUser: true) == .done
        )
    }

    @Test func theSidecarCarriesTheStopFlagAndTheModel() {
        let descriptor = SubagentMetadataReader.decode(Data(#"""
        {"agentType":"Explore","description":"Map the stack","model":"sonnet","stoppedByUser":true}
        """#.utf8))

        #expect(descriptor?.stoppedByUser == true)
        #expect(descriptor?.model == "sonnet")
    }

    @Test func anOrdinarySidecarIsNotStopped() {
        let descriptor = SubagentMetadataReader.decode(Data(#"{"agentType":"Explore"}"#.utf8))

        #expect(descriptor?.stoppedByUser == false)
        #expect(descriptor?.model == nil)
    }
}
