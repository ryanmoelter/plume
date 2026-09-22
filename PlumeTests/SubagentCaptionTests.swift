import Testing
import Foundation
@testable import Plume

/// The dim second line of a subagent row: model, elapsed time, context spent.
///
/// The span is measured from the transcript's own line timestamps, so it
/// survives a relaunch — the same rule the linger clock follows for the
/// opposite reason.
struct SubagentCaptionTests {
    private func line(at timestamp: String, model: String? = nil, contextTokens: Int? = nil) -> String {
        let modelField = model.map { #""model":"\#($0)","# } ?? ""
        let usage = contextTokens.map {
            #""usage":{"input_tokens":0,"cache_read_input_tokens":\#($0),"cache_creation_input_tokens":0,"output_tokens":0},"#
        } ?? ""
        return #"""
        {"type":"assistant","uuid":"\#(UUID().uuidString)","isSidechain":true,"timestamp":"\#(timestamp)","message":{"role":"assistant",\#(modelField)\#(usage)"stop_reason":"end_turn","content":[{"type":"text","text":"hi"}]}}
        """#
    }

    private func subagent(
        _ lines: [String],
        status: TaskStatus = .awaitingReply,
        descriptor: SubagentDescriptor? = nil
    ) -> SubagentTranscript {
        SubagentTranscript(
            id: "a1",
            transcript: TranscriptParser.parse(Data(lines.joined(separator: "\n").utf8), includeSidechain: true),
            modifiedAt: nil,
            descriptor: descriptor,
            status: status
        )
    }

    private func date(_ timestamp: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: timestamp) ?? .distantPast
    }

    @Test func theParserRecordsTheSpanOfTheConversation() {
        let parsed = subagent([
            line(at: "2026-09-05T22:00:00.000Z"),
            line(at: "2026-09-05T22:07:30.000Z"),
        ]).transcript

        #expect(parsed.startedAt == date("2026-09-05T22:00:00.000Z"))
        #expect(parsed.lastActivityAt == date("2026-09-05T22:07:30.000Z"))
    }

    /// A finished agent's clock stops at its last line, so a settled row does
    /// not go on counting up.
    @Test func aFinishedAgentIsTimedToItsLastLine() {
        let caption = SubagentCaption(
            subagent: subagent([
                line(at: "2026-09-05T22:00:00.000Z"),
                line(at: "2026-09-05T22:07:30.000Z"),
            ]),
            now: date("2026-09-05T23:00:00.000Z")
        )

        #expect(caption.elapsed == 450)
        #expect(caption.text == "7m")
    }

    @Test func aWorkingAgentIsTimedToNow() {
        let caption = SubagentCaption(
            subagent: subagent([line(at: "2026-09-05T22:00:00.000Z")], status: .working),
            now: date("2026-09-05T22:02:00.000Z")
        )

        #expect(caption.elapsed == 120)
    }

    @Test func theModelAndItsNominalWindowGiveThePercentage() {
        let caption = SubagentCaption(
            subagent: subagent([
                line(at: "2026-09-05T22:00:00.000Z", model: "claude-sonnet-5[1m]", contextTokens: 100_000)
            ]),
            now: date("2026-09-05T22:00:10.000Z")
        )

        #expect(caption.modelLabel == "Sonnet 5")
        #expect(caption.contextFraction == 0.1)
        #expect(caption.text == "Sonnet 5 · 0s · 10% context")
    }

    /// A model this build has never heard of implies no window, so the row
    /// states the model and drops the percentage rather than inventing one.
    @Test func anUnrecognizedModelHasNoPercentage() {
        let caption = SubagentCaption(
            subagent: subagent([
                line(at: "2026-09-05T22:00:00.000Z", model: "claude-newthing-9", contextTokens: 100_000)
            ]),
            now: date("2026-09-05T22:00:00.000Z")
        )

        #expect(caption.modelLabel == "Newthing 9")
        #expect(caption.contextFraction == nil)
    }

    /// The sidecar names a model before the agent has written an assistant
    /// line to read one from.
    @Test func theSidecarNamesTheModelBeforeTheTranscriptDoes() {
        let caption = SubagentCaption(
            subagent: subagent(
                [line(at: "2026-09-05T22:00:00.000Z")],
                descriptor: SubagentDescriptor(agentType: "Explore", model: "sonnet")
            ),
            now: date("2026-09-05T22:00:00.000Z")
        )

        #expect(caption.modelLabel == "Sonnet 5 200K")
    }

    @Test func aTranscriptWithNothingInItSaysNothing() {
        let caption = SubagentCaption(subagent: subagent([]))

        #expect(caption.text.isEmpty)
        #expect(caption.elapsed == nil)
        #expect(caption.contextFraction == nil)
    }

    @Test(arguments: [
        (0.0, "0s"), (45.0, "45s"), (59.6, "1m"), (60.0, "1m"), (3599.0, "59m"),
        (3600.0, "1h"), (5400.0, "1h 30m"), (-5.0, "0s"),
    ])
    func elapsedReadsCoarsely(seconds: TimeInterval, expected: String) {
        #expect(SubagentCaption.formatted(elapsed: seconds) == expected)
    }

    /// Usage past the window is a reporting artifact, not 130% of a context.
    @Test func aPercentageNeverPassesAHundred() {
        let caption = SubagentCaption(
            subagent: subagent([
                line(at: "2026-09-05T22:00:00.000Z", model: "claude-opus-5", contextTokens: 400_000)
            ])
        )

        #expect(caption.contextFraction == 1)
    }
}
