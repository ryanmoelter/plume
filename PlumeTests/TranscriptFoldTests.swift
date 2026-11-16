import Foundation
import Testing

@testable import Plume

/// Feeding a transcript in two pieces, reading the result at the split and
/// at the end, must match a parse of the same bytes from scratch. The
/// fixture packs every shape the tree rules and the two scans depend on into
/// one file, so each split lands somewhere different in them.
struct TranscriptFoldTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private static let lines: [String] = [
        #"{"type":"user","uuid":"u1","timestamp":"2026-01-01T00:00:00.000Z","sessionId":"s","cwd":"/repo","message":{"role":"user","content":"Hello café ✓"}}"#,
        #"{"type":"assistant","uuid":"a1","parentUuid":"u1","timestamp":"2026-01-01T00:00:01.000Z","message":{"id":"m1","role":"assistant","content":[{"type":"thinking","thinking":"hmm"}]}}"#,
        #"{"type":"assistant","uuid":"a2","parentUuid":"a1","message":{"id":"m1","role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"make","run_in_background":true,"description":"build"}}]}}"#,
        #"{"type":"progress","uuid":"p1","parentUuid":"a2"}"#,
        #"{"type":"user","uuid":"r1","parentUuid":"a2","timestamp":"2026-01-01T00:00:02.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"Command running in background with ID: bg1. Output is being written to: /tmp/bg1.output"}]}}"#,
        "not json at all",
        "",
        #"{"type":"assistant","uuid":"a3","parentUuid":"r1","message":{"id":"m2","role":"assistant","content":[{"type":"tool_use","id":"t2","name":"Agent","input":{"description":"explore","subagent_type":"Explore","prompt":"look"}}]}}"#,
        #"{"type":"assistant","uuid":"a4","parentUuid":"a3","message":{"id":"m2","role":"assistant","content":[{"type":"tool_use","id":"t3","name":"Monitor","input":{"description":"watch","persistent":false}}]}}"#,
        #"{"type":"attachment","uuid":"att1","parentUuid":"a4","attachment":{"type":"plan_mode","planFilePath":"/plans/a.md"}}"#,
        #"{"type":"user","uuid":"r2","parentUuid":"a4","toolUseResult":{"status":"async_launched","agentId":"agent123"},"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t2","content":"Async agent launched successfully.\nagentId: agent123 (explore)"}]}}"#,
        #"{"type":"user","uuid":"r3","parentUuid":"r2","timestamp":"2026-01-01T00:00:03.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t3","content":"Monitor started (task mon1, timeout 1800000ms)."}]}}"#,
        #"{"type":"user","uuid":"u2","parentUuid":"r3","message":{"role":"user","content":"first attempt"}}"#,
        #"{"type":"assistant","uuid":"a5","parentUuid":"u2","message":{"id":"m3","role":"assistant","content":[{"type":"text","text":"answer one"}]}}"#,
        #"{"type":"user","uuid":"u3","parentUuid":"r3","message":{"role":"user","content":"edited attempt"}}"#,
        #"{"type":"user","uuid":"u3","parentUuid":"r3","message":{"role":"user","content":"edited attempt"}}"#,
        #"{"type":"assistant","uuid":"a6","parentUuid":"u3","isApiErrorMessage":true,"message":{"id":"m4","role":"assistant","content":[{"type":"text","text":"overloaded"}]}}"#,
        #"{"type":"system","uuid":"s1","parentUuid":"u3","subtype":"api_error","level":"error","content":"boom","error":{"status":529,"error":{"message":"boom"}}}"#,
        #"{"type":"assistant","uuid":"a7","parentUuid":"s1","message":{"id":"m5","role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"answer two"}]}}"#,
        #"{"type":"queue-operation","uuid":"q1","operation":"enqueue","content":"<task-notification>\n<task-id>mon1</task-id>\n<summary>Monitor event</summary>\n<event>done</event>\n</task-notification>"}"#,
        #"{"type":"queue-operation","uuid":"q2","operation":"enqueue","content":"<task-notification>\n<task-id>agent123</task-id>\n<status>completed</status>\n<summary>Agent done</summary>\n</task-notification>"}"#,
        #"{"type":"system","uuid":"b1","parentUuid":null,"logicalParentUuid":"a7","subtype":"compact_boundary","content":"Conversation compacted","compactMetadata":{"trigger":"auto","preTokens":1000}}"#,
        #"{"type":"user","uuid":"u4","parentUuid":"b1","message":{"role":"user","content":"after compaction"}}"#,
        #"{"type":"assistant","uuid":"a8","parentUuid":"u4","message":{"id":"m6","role":"assistant","content":[{"type":"text","text":"final"}]}}"#,
    ]

    /// No trailing newline, so the file ends on a line still being written.
    private static let data = Data(lines.joined(separator: "\n").utf8)

    /// The fixture's lines before and from `split`, each as file bytes.
    private static func halves(at split: Int) -> (head: Data, tail: Data) {
        (
            Data(lines[..<split].joined(separator: "\n").utf8),
            Data(lines[split...].joined(separator: "\n").utf8)
        )
    }

    private static func decoded(_ data: Data) -> [TranscriptEntry] {
        Array(TranscriptParser.decodedEntries(in: data))
    }

    @Test func theFixtureExercisesWhatItClaims() {
        let transcript = TranscriptParser.parse(Self.data)
        #expect(transcript.forkPoints == ["r3"])
        #expect(transcript.abandonedBranches.values.flatMap { $0 }.map(\.id) == ["u2", "m3"])
        #expect(transcript.messages.last?.id == "m6")
        let midway = TranscriptParser.parse(Data(Self.lines.prefix(13).joined(separator: "\n").utf8))
        #expect(midway.messages.contains { $0.id == "m2" })
        let inFlight = BackgroundTaskScanner.inFlight(
            parentData: Data(Self.lines.prefix(12).joined(separator: "\n").utf8), now: Self.now
        )
        #expect(Set(inFlight.map(\.id)) == ["bg1", "mon1"])
        #expect(BackgroundTaskScanner.inFlight(parentData: Self.data, now: Self.now).map(\.id) == ["bg1"])
        #expect(SubagentSpawnResults(parentData: Self.data).signal(forAgentID: "agent123") == .completed)
    }

    @Test func theParserMatchesAFullParseAtEverySplit() {
        let whole = TranscriptParser.parse(Self.data)
        for split in 0...Self.lines.count {
            let (head, tail) = Self.halves(at: split)
            var state = TranscriptParser.State()
            Self.decoded(head).forEach { state.consume($0) }
            #expect(state.finished() == TranscriptParser.parse(head), "split \(split)")
            Self.decoded(tail).forEach { state.consume($0) }
            #expect(state.finished() == whole, "split \(split)")
        }
    }

    @Test func theBackgroundTaskScanMatchesAFullScanAtEverySplit() {
        let whole = BackgroundTaskScanner.inFlight(parentData: Self.data, now: Self.now)
        for split in 0...Self.lines.count {
            let (head, tail) = Self.halves(at: split)
            var state = BackgroundTaskScanner.State()
            Self.decoded(head).forEach { state.consume($0, now: Self.now) }
            #expect(
                state.inFlight == BackgroundTaskScanner.inFlight(parentData: head, now: Self.now),
                "split \(split)"
            )
            Self.decoded(tail).forEach { state.consume($0, now: Self.now) }
            #expect(state.inFlight == whole, "split \(split)")
        }
    }

    @Test func theSpawnResultsMatchAFullScanAtEverySplit() {
        let whole = SubagentSpawnResults(parentData: Self.data)
        for split in 0...Self.lines.count {
            let (head, tail) = Self.halves(at: split)
            var state = SubagentSpawnResults()
            Self.decoded(head).forEach { state.consume($0) }
            #expect(state == SubagentSpawnResults(parentData: head), "split \(split)")
            Self.decoded(tail).forEach { state.consume($0) }
            #expect(state == whole, "split \(split)")
        }
    }

    /// Splits at every byte, so most land mid-line — including inside a
    /// multi-byte character — and the line they cut must count only once
    /// it is whole.
    @Test func theFoldMatchesAFullReadAtEveryByte() {
        let data = Self.data
        let whole = Self.fullRead(data)
        for split in 0...data.count {
            var fold = TranscriptFold()
            let first = fold.append(data.prefix(split), now: Self.now)
            #expect(Self.matches(first, Self.fullRead(data.prefix(split))), "split \(split)")
            #expect(fold.consumed <= UInt64(split))
            let second = fold.append(data.dropFirst(Int(fold.consumed)), now: Self.now)
            #expect(Self.matches(second, whole), "split \(split)")
        }
    }

    /// A fold read twice with nothing new between must not double anything.
    @Test func readingTheFoldAgainWithNothingNewChangesNothing() {
        var fold = TranscriptFold()
        let first = fold.append(Self.data, now: Self.now)
        let consumed = fold.consumed
        let again = fold.append(Self.data.dropFirst(Int(consumed)), now: Self.now)
        #expect(fold.consumed == consumed)
        #expect(Self.matches(again, (first.transcript, first.backgroundTasks, first.spawnResults)))
    }

    private static func fullRead(
        _ data: Data
    ) -> (Transcript, [BackgroundTaskTracker.Entry], SubagentSpawnResults) {
        let data = Data(data)
        return (
            TranscriptParser.parse(data),
            BackgroundTaskScanner.inFlight(parentData: data, now: now),
            SubagentSpawnResults(parentData: data)
        )
    }

    private static func matches(
        _ snapshot: TranscriptFold.Snapshot,
        _ expected: (Transcript, [BackgroundTaskTracker.Entry], SubagentSpawnResults)
    ) -> Bool {
        snapshot.transcript == expected.0
            && snapshot.backgroundTasks == expected.1
            && snapshot.spawnResults == expected.2
    }
}
