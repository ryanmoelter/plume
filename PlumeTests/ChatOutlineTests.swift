import Foundation
import Testing
@testable import Plume

/// The outline the minimap draws: one entry per message, the user's prompts
/// carrying their opening line and everything else carrying only a weight.
@MainActor
struct ChatOutlineTests {
    private let dimensions = Dimensions(bodySize: 13)

    private func pieces(
        _ messages: [ChatMessage],
        streaming: ChatStreamHandoff.Overlay = .init()
    ) -> [ChatPiece] {
        ChatPieceSplitter.pieces(
            for: messages,
            status: .idle,
            hiddenToolUseIDs: [],
            streaming: streaming,
            dimensions: dimensions
        )
    }

    private func message(
        _ id: String,
        _ role: ChatMessage.Role = .assistant,
        _ blocks: [ChatBlock]
    ) -> ChatMessage {
        ChatMessage(id: id, role: role, blocks: blocks, timestamp: nil)
    }

    private func toolCall(_ id: String) -> ChatBlock {
        .toolCall(ToolCall(
            id: id,
            name: "Read",
            summary: ToolCallSummary(name: "Read", detail: "a file"),
            input: .json("{}")
        ))
    }

    private func outline(_ messages: [ChatMessage]) -> ChatOutline {
        ChatOutlineBuilder.outline(from: pieces(messages))
    }

    // MARK: - Structure

    @Test func everyMessageBecomesOneEntry() {
        let result = outline([
            message("a", .user, [.markdown("Ask something.")]),
            message("b", .assistant, [.markdown("First.\n\nSecond.\n\nThird.")]),
            message("c", .user, [.markdown("Ask again.")])
        ])

        #expect(result.entries.count == 3)
        #expect(result.entries.map(\.messageID) == ["a", "b", "c"])
    }

    @Test func aPromptCarriesItsOpeningLine() {
        let result = outline([
            message("a", .user, [.markdown("Add a minimap\nand make it nice.")])
        ])

        #expect(result.entries.first?.kind == .prompt("Add a minimap"))
    }

    @Test func theAgentAndTheTranscriptCarryNoText() {
        let result = outline([
            message("a", .assistant, [.markdown("A reply.")]),
            message("b", .notice, [.notice(ChatNotice(kind: .info, title: "Note", detail: nil))])
        ])

        #expect(result.entries.map(\.kind) == [.response, .notice])
    }

    @Test func anEntryScrollsToItsMessagesFirstPiece() {
        let all = pieces([message("a", .assistant, [.markdown("One.\n\nTwo.")])])
        let result = ChatOutlineBuilder.outline(from: all)

        #expect(result.entries.first?.id == all.first?.id)
    }

    @Test func theStreamIsNotAnEntry() {
        // The overlay stands in for a message the transcript has yet to take
        // over, so counting it would double the newest reply.
        let overlay = ChatStreamHandoff.Overlay(text: "Still writing")
        let result = ChatOutlineBuilder.outline(
            from: pieces([message("a", .user, [.markdown("Go.")])], streaming: overlay)
        )

        #expect(result.entries.map(\.messageID) == ["a"])
    }

    @Test func anEmptyConversationHasNoEntries() {
        #expect(outline([]).isEmpty)
        // Nothing divides by the total, whatever it holds.
        #expect(ChatOutline().totalWeight >= 1)
    }

    // MARK: - Weight

    @Test func alongerReplyOutweighsAShorterOne() throws {
        let result = outline([
            message("short", .assistant, [.markdown("Brief.")]),
            message("long", .assistant, [
                .markdown(String(repeating: "A sentence of some length. ", count: 40))
            ])
        ])

        let short = try #require(result.entries.first { $0.messageID == "short" })
        let long = try #require(result.entries.first { $0.messageID == "long" })
        #expect(long.weight > short.weight)
    }

    @Test func everyMessageKeepsAClickableFloor() {
        // A message that draws almost nothing still has to be big enough to
        // hit. A rule carries no text at all, where a one-word reply at least
        // weighs its line.
        let result = outline([
            message("a", .assistant, [.markdown("---")]),
            message("b", .assistant, [.markdown("Ok.")])
        ])

        #expect(result.entries.allSatisfy { $0.weight >= ChatOutlineBuilder.minimumWeight })
        #expect(result.entries.first?.weight == ChatOutlineBuilder.minimumWeight)
    }

    @Test func aToolCallWeighsItsRowRatherThanItsText() throws {
        // A collapsed call draws one short row whatever it contains, so its
        // input length says nothing about the room it takes.
        let result = outline([message("a", .assistant, [toolCall("t1"), toolCall("t2")])])

        let weight = try #require(result.entries.first?.weight)
        #expect(weight == ChatOutlineBuilder.toolCallWeight * 2)
    }

    @Test func aMessagesPiecesSumIntoOneWeight() throws {
        let one = outline([message("a", .assistant, [toolCall("t1")])])
        let two = outline([message("a", .assistant, [toolCall("t1"), toolCall("t2")])])

        let single = try #require(one.entries.first?.weight)
        let double = try #require(two.entries.first?.weight)
        #expect(double > single)
    }

    @Test func totalWeightSumsTheEntries() {
        let result = outline([
            message("a", .user, [.markdown("Ask.")]),
            message("b", .assistant, [.markdown("Answer.")])
        ])

        #expect(result.totalWeight == result.entries.reduce(0) { $0 + $1.weight })
    }
}
