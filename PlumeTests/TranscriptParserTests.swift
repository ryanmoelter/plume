import Testing
import Foundation
@testable import Plume

/// Fixtures mirror real transcript lines in `~/.claude/projects`.
struct TranscriptParserTests {
    private func data(_ lines: [String]) -> Data {
        Data(lines.joined(separator: "\n").utf8)
    }

    @Test func aPlainTextExchangeBecomesTwoMessages() {
        let transcript = TranscriptParser.parse(data([
            #"{"type":"user","uuid":"u1","isSidechain":false,"message":{"role":"user","content":"hello"}}"#,
            #"{"type":"assistant","uuid":"a1","isSidechain":false,"message":{"role":"assistant","content":[{"type":"text","text":"hi there"}]}}"#,
        ]))

        #expect(transcript.messages.count == 2)
        #expect(transcript.messages[0].role == .user)
        #expect(transcript.messages[1].role == .assistant)
        if case .markdown(let text) = transcript.messages[0].blocks.first {
            #expect(text == "hello")
        } else {
            Issue.record("expected markdown block for the user message")
        }
    }

    @Test func aBareStringUserMessageDecodesAsMarkdown() {
        let transcript = TranscriptParser.parse(data([
            #"{"type":"user","uuid":"u1","isSidechain":false,"message":{"role":"user","content":"just a string"}}"#,
        ]))

        #expect(transcript.messages.count == 1)
        if case .markdown(let text) = transcript.messages[0].blocks.first {
            #expect(text == "just a string")
        } else {
            Issue.record("expected a markdown block")
        }
    }

    @Test func aThinkingBlockIsPreserved() {
        let transcript = TranscriptParser.parse(data([
            #"{"type":"assistant","uuid":"a1","isSidechain":false,"message":{"role":"assistant","content":[{"type":"thinking","thinking":"let me consider"},{"type":"text","text":"done"}]}}"#,
        ]))

        #expect(transcript.messages.count == 1)
        let blocks = transcript.messages[0].blocks
        #expect(blocks.count == 2)
        if case .thinking(let text) = blocks[0] {
            #expect(text == "let me consider")
        } else {
            Issue.record("expected the first block to be thinking")
        }
    }

    @Test func aToolUseIsMatchedToItsResult() {
        let transcript = TranscriptParser.parse(data([
            #"""
            {"type":"assistant","uuid":"a1","isSidechain":false,"message":{"role":"assistant","content":[{"type":"tool_use","id":"tool-1","name":"Bash","input":{"command":"echo hi"}}]}}
            """#,
            #"""
            {"type":"user","uuid":"u1","isSidechain":false,"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tool-1","content":"hi"}]}}
            """#,
        ]))

        // The tool_result-only user line contributes no message of its own.
        #expect(transcript.messages.count == 1)
        guard case .toolCall(let call) = transcript.messages[0].blocks.first else {
            Issue.record("expected a tool call block")
            return
        }
        #expect(call.result == "hi")
        #expect(call.summary == "Bash(echo hi)")
    }

    @Test func toolResultContentAsAnArrayOfTextBlocksIsJoined() {
        let transcript = TranscriptParser.parse(data([
            #"""
            {"type":"assistant","uuid":"a1","isSidechain":false,"message":{"role":"assistant","content":[{"type":"tool_use","id":"tool-1","name":"Read","input":{"file_path":"/a/b.txt"}}]}}
            """#,
            #"""
            {"type":"user","uuid":"u1","isSidechain":false,"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tool-1","content":[{"type":"text","text":"file contents"}]}]}}
            """#,
        ]))

        guard case .toolCall(let call) = transcript.messages[0].blocks.first else {
            Issue.record("expected a tool call block")
            return
        }
        #expect(call.result == "file contents")
    }

    @Test func anUnmatchedToolUseKeepsANilResult() {
        let transcript = TranscriptParser.parse(data([
            #"""
            {"type":"assistant","uuid":"a1","isSidechain":false,"message":{"role":"assistant","content":[{"type":"tool_use","id":"tool-1","name":"Bash","input":{"command":"still running"}}]}}
            """#,
        ]))

        guard case .toolCall(let call) = transcript.messages[0].blocks.first else {
            Issue.record("expected a tool call block")
            return
        }
        #expect(call.result == nil)
    }

    @Test func consecutiveAssistantLinesFoldIntoOneMessage() {
        let transcript = TranscriptParser.parse(data([
            #"{"type":"assistant","uuid":"a1","isSidechain":false,"message":{"role":"assistant","content":[{"type":"text","text":"first"}]}}"#,
            #"""
            {"type":"assistant","uuid":"a2","isSidechain":false,"message":{"role":"assistant","content":[{"type":"tool_use","id":"tool-1","name":"Bash","input":{"command":"ls"}}]}}
            """#,
            #"{"type":"assistant","uuid":"a3","isSidechain":false,"message":{"role":"assistant","content":[{"type":"text","text":"second"}]}}"#,
        ]))

        #expect(transcript.messages.count == 1)
        #expect(transcript.messages[0].blocks.count == 3)
    }

    @Test func aSidechainLineIsSkipped() {
        let transcript = TranscriptParser.parse(data([
            #"{"type":"user","uuid":"u1","isSidechain":true,"message":{"role":"user","content":"from a subagent"}}"#,
            #"{"type":"user","uuid":"u2","isSidechain":false,"message":{"role":"user","content":"from the main thread"}}"#,
        ]))

        #expect(transcript.messages.count == 1)
        if case .markdown(let text) = transcript.messages[0].blocks.first {
            #expect(text == "from the main thread")
        } else {
            Issue.record("expected a markdown block")
        }
    }

    @Test func anUnknownTypeIsSkipped() {
        let transcript = TranscriptParser.parse(data([
            #"{"type":"cost-state","isSidechain":false}"#,
            #"{"type":"user","uuid":"u1","isSidechain":false,"message":{"role":"user","content":"hello"}}"#,
        ]))

        #expect(transcript.messages.count == 1)
    }

    @Test func nonMessageLineTypesAreSkipped() {
        let transcript = TranscriptParser.parse(data([
            #"{"type":"attachment","isSidechain":false}"#,
            #"{"type":"system","isSidechain":false}"#,
            #"{"type":"mode","isSidechain":false}"#,
            #"{"type":"permission-mode","isSidechain":false}"#,
            #"{"type":"last-prompt","isSidechain":false}"#,
            #"{"type":"ai-title","isSidechain":false}"#,
            #"{"type":"atis-latch","isSidechain":false}"#,
            #"{"type":"agent-name","isSidechain":false}"#,
            #"{"type":"queue-operation","isSidechain":false}"#,
            #"{"type":"file-history-snapshot","isSidechain":false}"#,
            #"{"type":"file-history-delta","isSidechain":false}"#,
            #"{"type":"cost-state","isSidechain":false}"#,
        ]))

        #expect(transcript.messages.isEmpty)
    }

    @Test func aMalformedLineMidFileDoesNotStopParsing() {
        let transcript = TranscriptParser.parse(data([
            #"{"type":"user","uuid":"u1","isSidechain":false,"message":{"role":"user","content":"before"}}"#,
            #"{"type":"user","message":{"role":"#,
            #"{"type":"user","uuid":"u2","isSidechain":false,"message":{"role":"user","content":"after"}}"#,
        ]))

        #expect(transcript.messages.count == 2)
        if case .markdown(let first) = transcript.messages[0].blocks.first,
           case .markdown(let second) = transcript.messages[1].blocks.first {
            #expect(first == "before")
            #expect(second == "after")
        } else {
            Issue.record("expected markdown blocks on both surviving messages")
        }
    }

    @Test func latestUsageModelEffortAndSessionMetadataComeFromTheLastLineCarryingThem() {
        let transcript = TranscriptParser.parse(data([
            #"""
            {"type":"assistant","uuid":"a1","isSidechain":false,"effort":"low","gitBranch":"main","cwd":"/repo","sessionId":"s1","message":{"role":"assistant","model":"claude-opus-5","usage":{"input_tokens":10,"cache_creation_input_tokens":1,"cache_read_input_tokens":2,"output_tokens":5},"content":[{"type":"text","text":"one"}]}}
            """#,
            #"""
            {"type":"assistant","uuid":"a2","isSidechain":false,"effort":"high","gitBranch":"feature","cwd":"/repo2","sessionId":"s2","message":{"role":"assistant","model":"claude-sonnet-5","usage":{"input_tokens":20,"cache_creation_input_tokens":3,"cache_read_input_tokens":4,"output_tokens":6},"content":[{"type":"text","text":"two"}]}}
            """#,
        ]))

        #expect(transcript.model == "claude-sonnet-5")
        #expect(transcript.effort == "high")
        #expect(transcript.gitBranch == "feature")
        #expect(transcript.cwd == "/repo2")
        #expect(transcript.sessionID == "s2")
        #expect(transcript.latestUsage?.inputTokens == 20)
        #expect(transcript.latestUsage?.outputTokens == 6)
    }

    @Test func emptyAndBlankLinesAreIgnored() {
        let transcript = TranscriptParser.parse(data([
            "",
            #"{"type":"user","uuid":"u1","isSidechain":false,"message":{"role":"user","content":"hello"}}"#,
            "",
        ]))

        #expect(transcript.messages.count == 1)
    }
}
