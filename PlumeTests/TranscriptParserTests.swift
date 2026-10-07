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

    @Test func anEmptyThinkingBlockIsDropped() {
        let transcript = TranscriptParser.parse(data([
            #"{"type":"assistant","uuid":"a1","isSidechain":false,"message":{"id":"msg_1","role":"assistant","content":[{"type":"thinking","thinking":"","signature":"abc"}]}}"#,
            #"{"type":"assistant","uuid":"a2","isSidechain":false,"message":{"id":"msg_1","role":"assistant","content":[{"type":"text","text":"done"}]}}"#,
        ]))

        let blocks = transcript.messages.flatMap(\.blocks)
        #expect(blocks.count == 1)
        if case .markdown(let text) = blocks.first {
            #expect(text == "done")
        } else {
            Issue.record("expected only the text block")
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
        #expect(!call.didFail)
        #expect(call.summary.plainText == "Bash: echo hi…")
    }

    @Test func aFailedResultMarksItsCall() {
        let transcript = TranscriptParser.parse(data([
            #"""
            {"type":"assistant","uuid":"a1","isSidechain":false,"message":{"role":"assistant","content":[{"type":"tool_use","id":"tool-1","name":"Bash","input":{"command":"false"}}]}}
            """#,
            #"""
            {"type":"user","uuid":"u1","isSidechain":false,"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tool-1","content":"boom","is_error":true}]}}
            """#,
        ]))

        guard case .toolCall(let call) = transcript.messages[0].blocks.first else {
            Issue.record("expected a tool call block")
            return
        }
        #expect(call.didFail)
        #expect(call.result == "boom")
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

    @Test func aToolSearchResultOfToolReferencesFinishesTheCall() {
        let transcript = TranscriptParser.parse(data([
            #"""
            {"type":"assistant","uuid":"a1","isSidechain":false,"message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_01DLxc3C6yZ5t8u283k9DJcL","name":"ToolSearch","input":{"query":"select:TaskStop,Monitor","max_results":3},"caller":{"type":"direct"}}]}}
            """#,
            #"""
            {"type":"user","uuid":"u1","isSidechain":false,"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_01DLxc3C6yZ5t8u283k9DJcL","content":[{"type":"tool_reference","tool_name":"TaskStop"},{"type":"tool_reference","tool_name":"Monitor"}]}]},"toolUseResult":{"matches":["TaskStop","Monitor"],"query":"select:TaskStop,Monitor","total_deferred_tools":98}}
            """#,
        ]))

        guard case .toolCall(let call) = transcript.messages[0].blocks.first else {
            Issue.record("expected a tool call block")
            return
        }
        #expect(call.result == "TaskStop\nMonitor")
    }

    @Test func aResultWithNothingReadableStillFinishesTheCall() {
        let transcript = TranscriptParser.parse(data([
            #"""
            {"type":"assistant","uuid":"a1","isSidechain":false,"message":{"role":"assistant","content":[{"type":"tool_use","id":"tool-1","name":"Future","input":{}}]}}
            """#,
            #"""
            {"type":"user","uuid":"u1","isSidechain":false,"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tool-1","content":[{"type":"unmodeled_block"}]}]}}
            """#,
        ]))

        guard case .toolCall(let call) = transcript.messages[0].blocks.first else {
            Issue.record("expected a tool call block")
            return
        }
        #expect(call.result == "")
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

    @Test func aPlanModeAttachmentSurfacesThePlanPath() {
        let transcript = TranscriptParser.parse(data([
            #"{"isSidechain":false,"attachment":{"type":"plan_mode","reminderType":"full","isSubAgent":false,"planFilePath":"/Users/example/.claude/plans/first-plan.md","planExists":false},"type":"attachment","uuid":"u1"}"#,
        ]))

        #expect(transcript.planFilePath == "/Users/example/.claude/plans/first-plan.md")
        #expect(transcript.messages.isEmpty)
    }

    @Test func aPlanModeExitAttachmentSurfacesThePlanPath() {
        let transcript = TranscriptParser.parse(data([
            #"{"isSidechain":false,"attachment":{"type":"plan_mode_exit","planFilePath":"/Users/example/.claude/plans/first-plan.md","planExists":true},"type":"attachment","uuid":"u1"}"#,
        ]))

        #expect(transcript.planFilePath == "/Users/example/.claude/plans/first-plan.md")
        #expect(transcript.messages.isEmpty)
    }

    @Test func theLatestPlanPathWins() {
        let transcript = TranscriptParser.parse(data([
            #"{"isSidechain":false,"attachment":{"type":"plan_mode","planFilePath":"/plans/first.md","planExists":false},"type":"attachment","uuid":"u1"}"#,
            #"{"isSidechain":false,"attachment":{"type":"plan_mode_exit","planFilePath":"/plans/second.md","planExists":false},"type":"attachment","uuid":"u2"}"#,
        ]))

        #expect(transcript.planFilePath == "/plans/second.md")
    }

    @Test func aMalformedAttachmentIsIgnoredWithoutThrowing() {
        let transcript = TranscriptParser.parse(data([
            #"{"isSidechain":false,"attachment":{"type":"plan_mode","planFilePath":123},"type":"attachment","uuid":"u1"}"#,
            #"{"type":"user","uuid":"u2","isSidechain":false,"message":{"role":"user","content":"still works"}}"#,
        ]))

        #expect(transcript.planFilePath == nil)
        #expect(transcript.messages.count == 1)
    }

    @Test func anAttachmentWithNoPlanFilePathLeavesThePathUnset() {
        let transcript = TranscriptParser.parse(data([
            #"{"isSidechain":false,"attachment":{"type":"plan_mode","reminderType":"full"},"type":"attachment","uuid":"u1"}"#,
        ]))

        #expect(transcript.planFilePath == nil)
    }

    @Test func anUnrecognizedAttachmentTypeIsIgnored() {
        let transcript = TranscriptParser.parse(data([
            #"{"isSidechain":false,"attachment":{"type":"some_future_attachment","planFilePath":"/plans/x.md"},"type":"attachment","uuid":"u1"}"#,
        ]))

        #expect(transcript.planFilePath == nil)
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

    @Test func aSkillBodyBecomesAMarkerNotAUserMessage() {
        let transcript = TranscriptParser.parse(data([
            #"{"type":"user","uuid":"u1","isSidechain":false,"isMeta":true,"message":{"role":"user","content":"Base directory for this skill: /Users/x/.claude/skills/debug\n\nbody"}}"#,
        ]))

        #expect(transcript.messages.count == 1)
        if case .injected(let kind, let text) = transcript.messages[0].blocks.first {
            #expect(kind == .skill(name: "debug"))
            #expect(text.contains("body"))
        } else {
            Issue.record("expected an injected block")
        }
    }

    @Test func aSlashCommandExpansionBecomesAMarkerDespiteNotBeingMeta() {
        let transcript = TranscriptParser.parse(data([
            #"{"type":"user","uuid":"u1","isSidechain":false,"message":{"role":"user","content":"<command-name>/compact</command-name>"}}"#,
        ]))

        if case .injected(let kind, _) = transcript.messages[0].blocks.first {
            #expect(kind == .slashCommand(name: "/compact"))
        } else {
            Issue.record("expected an injected block")
        }
    }

    @Test func aTypedMessageStaysMarkdown() {
        let transcript = TranscriptParser.parse(data([
            #"{"type":"user","uuid":"u1","isSidechain":false,"message":{"role":"user","content":"reconcile the roadmap"}}"#,
        ]))

        if case .markdown(let text) = transcript.messages[0].blocks.first {
            #expect(text == "reconcile the roadmap")
        } else {
            Issue.record("expected a markdown block")
        }
    }

    /// A tool result rides on the same line as an injected marker in real
    /// transcripts, so the result must still reach its call.
    @Test func anInjectedLineStillDeliversItsToolResult() {
        let transcript = TranscriptParser.parse(data([
            #"{"type":"assistant","uuid":"a1","isSidechain":false,"message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}}]}}"#,
            #"{"type":"user","uuid":"u1","isSidechain":false,"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"out"},{"type":"text","text":"<task-notification>done</task-notification>"}]}}"#,
        ]))

        if case .toolCall(let call) = transcript.messages[0].blocks.first {
            #expect(call.result == "out")
        } else {
            Issue.record("expected the tool call to keep its result")
        }
        if case .injected(let kind, _) = transcript.messages[1].blocks.first {
            #expect(kind == .taskNotification)
        } else {
            Issue.record("expected an injected block alongside the result")
        }
    }

    @Test func latestPermissionModeWins() {
        let transcript = TranscriptParser.parse(data([
            #"{"type":"permission-mode","permissionMode":"plan","isSidechain":false}"#,
            #"{"type":"permission-mode","permissionMode":"auto","isSidechain":false}"#,
        ]))

        #expect(transcript.permissionMode == "auto")
    }

    @Test func noPermissionModeLineLeavesItUnset() {
        let transcript = TranscriptParser.parse(data([
            #"{"type":"permission-mode","isSidechain":false}"#,
        ]))

        #expect(transcript.permissionMode == nil)
    }
}

/// Covers the branch tree built out of `parentUuid`. Fixtures mirror the
/// shapes measured across a 319-transcript corpus scan.
struct TranscriptParserForkTests {
    private func data(_ lines: [String]) -> Data {
        Data(lines.joined(separator: "\n").utf8)
    }

    @Test func anAttachmentSharingAParentDoesNotRegisterAsAFork() {
        let transcript = TranscriptParser.parse(data([
            #"{"type":"user","uuid":"p1","isSidechain":false,"message":{"role":"user","content":"hello"}}"#,
            #"{"type":"assistant","uuid":"c1","parentUuid":"p1","isSidechain":false,"message":{"role":"assistant","content":[{"type":"text","text":"hi"}]}}"#,
            #"{"type":"attachment","uuid":"c2","parentUuid":"p1","isSidechain":false,"attachment":{"type":"plan_mode","planFilePath":"/plans/a.md"}}"#,
        ]))

        #expect(transcript.forkPoints.isEmpty)
        #expect(transcript.abandonedBranches.isEmpty)
    }

    @Test func chainedAttachmentsDoNotRegisterAsAFork() {
        let transcript = TranscriptParser.parse(data([
            #"{"type":"user","uuid":"p1","isSidechain":false,"message":{"role":"user","content":"hello"}}"#,
            #"{"type":"attachment","uuid":"a1","parentUuid":"p1","isSidechain":false,"attachment":{"type":"plan_mode","planFilePath":"/plans/a.md"}}"#,
            #"{"type":"attachment","uuid":"a2","parentUuid":"a1","isSidechain":false,"attachment":{"type":"plan_mode_exit","planFilePath":"/plans/a.md"}}"#,
            #"{"type":"assistant","uuid":"c1","parentUuid":"a1","isSidechain":false,"message":{"role":"assistant","content":[{"type":"text","text":"hi"}]}}"#,
        ]))

        #expect(transcript.forkPoints.isEmpty)
    }

    @Test func duplicateUuidRowsDedupeRatherThanForking() {
        let duplicated = #"""
        {"type":"user","uuid":"u1","parentUuid":"p1","isSidechain":false,"message":{"role":"user","content":"hello"}}
        """#
        let transcript = TranscriptParser.parse(data([
            #"{"type":"user","uuid":"p1","isSidechain":false,"message":{"role":"user","content":"start"}}"#,
            duplicated,
            duplicated,
        ]))

        #expect(transcript.forkPoints.isEmpty)
        #expect(transcript.messages.count == 2)
    }

    /// The fork action cuts at the target's parent, so the parse has to name
    /// one for every row — including an attachment, which never becomes a
    /// rendered message but can still sit between two that do.
    @Test func everyRowsParentIsRecordedIncludingAttachments() {
        let transcript = TranscriptParser.parse(data([
            #"{"type":"user","uuid":"p1","isSidechain":false,"message":{"role":"user","content":"hello"}}"#,
            #"{"type":"attachment","uuid":"a1","parentUuid":"p1","isSidechain":false,"attachment":{"type":"plan_mode","planFilePath":"/plans/a.md"}}"#,
            #"{"type":"assistant","uuid":"c1","parentUuid":"a1","isSidechain":false,"message":{"role":"assistant","content":[{"type":"text","text":"hi"}]}}"#,
        ]))

        #expect(transcript.parentByMessageID["a1"] == "p1")
        #expect(transcript.parentByMessageID["c1"] == "a1")
        // The root names no parent rather than naming itself.
        #expect(transcript.parentByMessageID["p1"] == nil)
    }

    @Test func anApiErrorRetryPairIsExcluded() {
        let transcript = TranscriptParser.parse(data([
            #"{"type":"user","uuid":"p1","isSidechain":false,"message":{"role":"user","content":"hello"}}"#,
            #"""
            {"type":"assistant","uuid":"a1","parentUuid":"p1","isSidechain":false,"isApiErrorMessage":true,"message":{"role":"assistant","content":[{"type":"text","text":"error"}]}}
            """#,
            #"""
            {"type":"system","uuid":"s1","parentUuid":"p1","isSidechain":false,"subtype":"api_error","level":"error","content":"boom","error":{"status":500,"error":{"message":"boom"}}}
            """#,
        ]))

        #expect(transcript.forkPoints.isEmpty)
        #expect(transcript.abandonedBranches.isEmpty)
    }

    @Test func aGenuineUserUserForkIsDetectedAndBothBranchesAreWalkable() {
        let transcript = TranscriptParser.parse(data([
            #"{"type":"user","uuid":"p1","isSidechain":false,"message":{"role":"user","content":"original question"}}"#,
            #"{"type":"user","uuid":"c1","parentUuid":"p1","isSidechain":false,"message":{"role":"user","content":"edited question"}}"#,
            #"{"type":"user","uuid":"c2","parentUuid":"p1","isSidechain":false,"message":{"role":"user","content":"edited again"}}"#,
        ]))

        #expect(transcript.forkPoints == ["p1"])

        #expect(transcript.messages.contains { $0.id == "c2" })

        let abandoned = transcript.abandonedBranches["p1"]
        #expect(abandoned?.count == 1)
        #expect(abandoned?.first?.id == "c1")
    }

    @Test func aSingleChildIsNotAFork() {
        let transcript = TranscriptParser.parse(data([
            #"{"type":"user","uuid":"p1","isSidechain":false,"message":{"role":"user","content":"hello"}}"#,
            #"{"type":"assistant","uuid":"c1","parentUuid":"p1","isSidechain":false,"message":{"role":"assistant","content":[{"type":"text","text":"hi"}]}}"#,
        ]))

        #expect(transcript.forkPoints.isEmpty)
    }

    /// The surviving branch is whichever child's line reaches the file's
    /// last row, not whichever child's own row appears last. Here `earlier`
    /// forks off `p1` and is followed by its own reply (`a1`) — so `earlier`
    /// is not the last *row* in the file — but nothing follows `later`, so
    /// `earlier`/`a1` is the branch that is actually live and `later` is the
    /// one left behind. A rule that just dropped the last *child of the
    /// fork* would get this backwards, since `later` is that last child.
    @Test func theSurvivingBranchIsDeterminedByTheFinalRowNotByFileOrder() {
        let transcript = TranscriptParser.parse(data([
            #"{"type":"user","uuid":"p1","isSidechain":false,"message":{"role":"user","content":"original question"}}"#,
            #"{"type":"user","uuid":"earlier","parentUuid":"p1","isSidechain":false,"message":{"role":"user","content":"kept branch"}}"#,
            #"{"type":"user","uuid":"later","parentUuid":"p1","isSidechain":false,"message":{"role":"user","content":"edited later"}}"#,
            #"""
            {"type":"assistant","uuid":"a1","parentUuid":"earlier","isSidechain":false,"message":{"role":"assistant","content":[{"type":"text","text":"reply"}]}}
            """#,
        ]))

        #expect(transcript.forkPoints == ["p1"])
        #expect(transcript.messages.contains { $0.id == "earlier" })
        #expect(transcript.messages.contains { $0.id == "a1" })

        let abandoned = transcript.abandonedBranches["p1"]
        #expect(abandoned?.count == 1)
        #expect(abandoned?.first?.id == "later")
    }

    /// An abandoned branch can itself be several rows deep — the whole
    /// subtree needs to come back, not just the forked row itself.
    @Test func anAbandonedBranchSeveralRowsDeepIsCollectedInFull() {
        let transcript = TranscriptParser.parse(data([
            #"{"type":"user","uuid":"p1","isSidechain":false,"message":{"role":"user","content":"original question"}}"#,
            #"{"type":"user","uuid":"abandoned1","parentUuid":"p1","isSidechain":false,"message":{"role":"user","content":"edited question"}}"#,
            #"""
            {"type":"assistant","uuid":"abandoned2","parentUuid":"abandoned1","isSidechain":false,"message":{"role":"assistant","content":[{"type":"text","text":"reply on the dead branch"}]}}
            """#,
            #"{"type":"user","uuid":"survivor","parentUuid":"p1","isSidechain":false,"message":{"role":"user","content":"edited again"}}"#,
        ]))

        #expect(transcript.forkPoints == ["p1"])
        let abandoned = transcript.abandonedBranches["p1"]
        #expect(abandoned?.map(\.id) == ["abandoned1", "abandoned2"])
    }

    /// The branch-collection walk has to follow attachments even though
    /// fork detection ignores them. Attachments chain, so a branch that runs
    /// through one loses every row below it when the walk stops there.
    @Test func anAbandonedBranchIsCollectedThroughAnAttachment() {
        let transcript = TranscriptParser.parse(data([
            #"{"type":"user","uuid":"p1","isSidechain":false,"message":{"role":"user","content":"original question"}}"#,
            #"{"type":"user","uuid":"abandoned1","parentUuid":"p1","isSidechain":false,"message":{"role":"user","content":"edited question"}}"#,
            #"{"type":"attachment","uuid":"att","parentUuid":"abandoned1","isSidechain":false,"attachment":{"type":"plan_mode","planFilePath":"/plans/a.md"}}"#,
            #"""
            {"type":"assistant","uuid":"abandoned2","parentUuid":"att","isSidechain":false,"message":{"role":"assistant","content":[{"type":"text","text":"reply below the attachment"}]}}
            """#,
            #"{"type":"user","uuid":"survivor","parentUuid":"p1","isSidechain":false,"message":{"role":"user","content":"edited again"}}"#,
        ]))

        #expect(transcript.forkPoints == ["p1"])
        #expect(transcript.abandonedBranches["p1"]?.map(\.id) == ["abandoned1", "abandoned2"])
    }

    /// The shape a rollback leaves: the abandoned reply carries its API
    /// message id, not its row uuid, and still has to leave the chat. The
    /// branch is keyed by the reply the fork hangs below, under the id it
    /// renders with.
    @Test func theChatShowsOnlyTheLiveBranch() {
        let transcript = TranscriptParser.parse(data([
            #"{"type":"user","uuid":"u1","isSidechain":false,"message":{"role":"user","content":"say APPLE"}}"#,
            #"{"type":"assistant","uuid":"r1","parentUuid":"u1","isSidechain":false,"message":{"id":"msg_apple","role":"assistant","content":[{"type":"text","text":"APPLE"}]}}"#,
            #"{"type":"user","uuid":"u2","parentUuid":"r1","isSidechain":false,"message":{"role":"user","content":"say BANANA"}}"#,
            #"{"type":"assistant","uuid":"r2","parentUuid":"u2","isSidechain":false,"message":{"id":"msg_banana","role":"assistant","content":[{"type":"text","text":"BANANA"}]}}"#,
            #"{"type":"user","uuid":"u3","parentUuid":"r1","isSidechain":false,"message":{"role":"user","content":"say DATE"}}"#,
            #"{"type":"assistant","uuid":"r3","parentUuid":"u3","isSidechain":false,"message":{"id":"msg_date","role":"assistant","content":[{"type":"text","text":"DATE"}]}}"#,
        ]))

        #expect(transcript.messages.map(\.id) == ["u1", "msg_apple", "u3", "msg_date"])
        #expect(transcript.abandonedBranches["msg_apple"]?.map(\.id) == ["u2", "msg_banana"])
    }

    /// A compaction restarts the chain: the boundary row has a null
    /// `parentUuid` and names the row it continued from only as
    /// `logicalParentUuid`.
    @Test func aForkBeforeACompactionKeepsTheBranchTheCompactionContinued() {
        let transcript = TranscriptParser.parse(data([
            #"{"type":"user","uuid":"u1","isSidechain":false,"message":{"role":"user","content":"start"}}"#,
            #"{"type":"assistant","uuid":"r1","parentUuid":"u1","isSidechain":false,"message":{"id":"msg_1","role":"assistant","content":[{"type":"text","text":"one"}]}}"#,
            #"{"type":"user","uuid":"u2","parentUuid":"r1","isSidechain":false,"message":{"role":"user","content":"abandoned"}}"#,
            #"{"type":"user","uuid":"u3","parentUuid":"r1","isSidechain":false,"message":{"role":"user","content":"kept"}}"#,
            #"{"type":"assistant","uuid":"r3","parentUuid":"u3","isSidechain":false,"message":{"id":"msg_3","role":"assistant","content":[{"type":"text","text":"three"}]}}"#,
            #"{"type":"system","uuid":"b1","parentUuid":null,"logicalParentUuid":"r3","isSidechain":false,"subtype":"compact_boundary","content":"Conversation compacted","compactMetadata":{"trigger":"auto","preTokens":1000}}"#,
            #"{"type":"user","uuid":"u5","parentUuid":"b1","isSidechain":false,"message":{"role":"user","content":"after"}}"#,
        ]))

        #expect(transcript.messages.map(\.id).contains("u3"))
        #expect(transcript.messages.map(\.id).contains("msg_3"))
        #expect(transcript.abandonedBranches["msg_1"]?.map(\.id) == ["u2"])
    }

    /// When the live walk reaches none of a fork's children, abandoning all
    /// of them would hide the conversation the file actually kept.
    @Test func aForkWithNoLiveChildHidesNothing() {
        let transcript = TranscriptParser.parse(data([
            #"{"type":"user","uuid":"u1","isSidechain":false,"message":{"role":"user","content":"start"}}"#,
            #"{"type":"user","uuid":"u2","parentUuid":"u1","isSidechain":false,"message":{"role":"user","content":"first"}}"#,
            #"{"type":"user","uuid":"u3","parentUuid":"u1","isSidechain":false,"message":{"role":"user","content":"second"}}"#,
            #"{"type":"user","uuid":"orphan","parentUuid":"missing","isSidechain":false,"message":{"role":"user","content":"unattached"}}"#,
        ]))

        #expect(transcript.messages.map(\.id) == ["u1", "u2", "u3", "orphan"])
        #expect(transcript.abandonedBranches.isEmpty)
    }

    /// Two assistant rows answering the same parent are siblings on separate
    /// branches, so they cannot merge into one reply — abandoning one would
    /// then hide the other.
    @Test func siblingAssistantRowsDoNotMergeIntoOneReply() {
        let transcript = TranscriptParser.parse(data([
            #"{"type":"user","uuid":"u1","isSidechain":false,"message":{"role":"user","content":"hi"}}"#,
            #"{"type":"assistant","uuid":"a1","parentUuid":"u1","isSidechain":false,"message":{"id":"msg_1","role":"assistant","content":[{"type":"text","text":"partial attempt"}]}}"#,
            #"{"type":"assistant","uuid":"a2","parentUuid":"u1","isSidechain":false,"message":{"id":"msg_2","role":"assistant","content":[{"type":"text","text":"retried answer"}]}}"#,
            #"{"type":"user","uuid":"u2","parentUuid":"a2","isSidechain":false,"message":{"role":"user","content":"next"}}"#,
        ]))

        #expect(transcript.messages.map(\.id) == ["u1", "msg_2", "u2"])
        #expect(transcript.abandonedBranches["u1"]?.map(\.id) == ["msg_1"])
    }

    /// A `progress` row hanging off a tool call is a side leaf, not a branch,
    /// even when it is the file's last row.
    @Test func aTrailingProgressLeafHidesNothing() {
        let transcript = TranscriptParser.parse(data([
            #"{"type":"user","uuid":"u1","isSidechain":false,"message":{"role":"user","content":"run it"}}"#,
            #"{"type":"assistant","uuid":"a1","parentUuid":"u1","isSidechain":false,"message":{"id":"msg_1","role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}}]}}"#,
            #"{"type":"user","uuid":"r1","parentUuid":"a1","isSidechain":false,"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}"#,
            #"{"type":"assistant","uuid":"a2","parentUuid":"r1","isSidechain":false,"message":{"id":"msg_2","role":"assistant","content":[{"type":"text","text":"done"}]}}"#,
            #"{"type":"progress","uuid":"p1","parentUuid":"a1","isSidechain":false}"#,
        ]))

        #expect(transcript.messages.map(\.id) == ["u1", "msg_1", "msg_2"])
        #expect(transcript.forkPoints.isEmpty)
        #expect(transcript.abandonedBranches.isEmpty)
    }

    /// One reply's rows chain through each other and through attachments
    /// between them, and still render as one message.
    @Test func aReplysChainedRowsStillMerge() {
        let transcript = TranscriptParser.parse(data([
            #"{"type":"user","uuid":"u1","isSidechain":false,"message":{"role":"user","content":"hi"}}"#,
            #"{"type":"assistant","uuid":"a1","parentUuid":"u1","isSidechain":false,"message":{"id":"msg_1","role":"assistant","content":[{"type":"thinking","thinking":"hmm"}]}}"#,
            #"{"type":"attachment","uuid":"att","parentUuid":"a1","isSidechain":false,"attachment":{"type":"plan_mode","planFilePath":"/plans/a.md"}}"#,
            #"{"type":"assistant","uuid":"a2","parentUuid":"att","isSidechain":false,"message":{"id":"msg_1","role":"assistant","content":[{"type":"text","text":"answer"}]}}"#,
        ]))

        #expect(transcript.messages.map(\.id) == ["u1", "msg_1"])
        #expect(transcript.messages.last?.blocks.count == 2)
    }
}
