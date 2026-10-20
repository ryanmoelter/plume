import Foundation
import Testing
@testable import Plume

/// A message the user sends while a turn runs joins that turn, and the CLI
/// records it as a `queued_command` attachment rather than a `user` line. It
/// renders as the user's message, between the replies it split. Every other
/// queued command — task notifications, agent and harness messages — stays
/// out of the chat.
///
/// Rows trimmed from `claude` 2.1.304 transcripts: a stream-json host's
/// message (block array, no `origin`) and a TUI one (string, `human`).
struct MidTurnUserMessageTests {
    private func parse(_ lines: [String]) -> Transcript {
        TranscriptParser.parse(Data(lines.joined(separator: "\n").utf8))
    }

    private func turn(around attachment: String) -> [String] {
        [
            #"{"type":"assistant","uuid":"a1","parentUuid":null,"isSidechain":false,"message":{"id":"msg_1","role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"sleep 3"}}]}}"#,
            #"{"type":"user","uuid":"u1","parentUuid":"a1","isSidechain":false,"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"(Bash completed with no output)"}]}}"#,
            attachment,
            #"{"type":"assistant","uuid":"a2","parentUuid":"q1","isSidechain":false,"message":{"id":"msg_2","role":"assistant","content":[{"type":"text","text":"PINEAPPLE"}]}}"#,
        ]
    }

    private func text(_ message: ChatMessage) -> String? {
        guard case .markdown(let text) = message.blocks.first else { return nil }
        return text
    }

    @Test func aHostMessageRendersBetweenTheRepliesItSplit() {
        let transcript = parse(turn(around:
            #"{"type":"attachment","uuid":"q1","parentUuid":"u1","isSidechain":false,"attachment":{"type":"queued_command","prompt":[{"type":"text","text":"Also say PINEAPPLE."}],"source_uuid":"s1","commandMode":"prompt"}}"#
        ))

        #expect(transcript.messages.map(\.role) == [.assistant, .user, .assistant])
        #expect(text(transcript.messages[1]) == "Also say PINEAPPLE.")
        #expect(transcript.messages[1].id == "q1")
    }

    @Test func aTypedTUIMessageRendersToo() {
        let transcript = parse(turn(around:
            #"{"type":"attachment","uuid":"q1","parentUuid":"u1","isSidechain":false,"attachment":{"type":"queued_command","prompt":"Also say PINEAPPLE.","commandMode":"prompt","origin":{"kind":"human"},"humanTurn":true}}"#
        ))

        #expect(transcript.messages.map(\.role) == [.assistant, .user, .assistant])
        #expect(text(transcript.messages[1]) == "Also say PINEAPPLE.")
    }

    @Test(arguments: [
        #"{"type":"queued_command","prompt":"<task-notification>\n<task-id>a1</task-id>\n</task-notification>","commandMode":"task-notification"}"#,
        #"{"type":"queued_command","prompt":"<agent-message from=\"a6\">report</agent-message>","commandMode":"prompt","isMeta":true,"origin":{"kind":"peer"}}"#,
        #"{"type":"queued_command","prompt":"from a coordinator","isMeta":true,"origin":{"kind":"coordinator"}}"#,
        #"{"type":"queued_command","prompt":"a report","commandMode":"prompt","origin":{"kind":"observer","from":"x","senderTaskId":"y"}}"#,
    ])
    func otherQueuedCommandsStayOut(attachment: String) {
        let transcript = parse(turn(around:
            #"{"type":"attachment","uuid":"q1","parentUuid":"u1","isSidechain":false,"attachment":"# + attachment + "}"
        ))

        #expect(!transcript.messages.contains { $0.role == .user })
    }
}
