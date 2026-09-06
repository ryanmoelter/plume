import Foundation
import Testing
@testable import Plume

@MainActor
struct ChatBlockSpacingTests {
    private let dimensions = Dimensions(bodySize: 13)

    private func toolCall(id: String = "1") -> ChatBlock {
        .toolCall(ToolCall(id: id, name: "Read", summary: "Read a file", input: .json("{}")))
    }

    private func message(id: String, role: ChatMessage.Role, blocks: [ChatBlock]) -> ChatMessage {
        ChatMessage(id: id, role: role, blocks: blocks, timestamp: nil)
    }

    @Test func onlyTheToolCallBlockCollapses() {
        #expect(ChatBlockSpacing.kind(of: toolCall()) == .toolCall)
        #expect(ChatBlockSpacing.kind(of: .markdown("hi")) == .other)
        #expect(ChatBlockSpacing.kind(of: .thinking("hm")) == .other)
    }

    @Test func aMessageOfNothingButToolCallsContinuesARun() {
        #expect(ChatBlockSpacing.rowKind(of: message(
            id: "a",
            role: .assistant,
            blocks: [toolCall(id: "1"), toolCall(id: "2")]
        )) == .toolCall)
        #expect(ChatBlockSpacing.rowKind(of: message(
            id: "b",
            role: .assistant,
            blocks: [toolCall(), .markdown("done")]
        )) == .other)
        #expect(ChatBlockSpacing.rowKind(of: message(id: "c", role: .user, blocks: [])) == .other)
    }

    @Test func consecutiveToolCallsSitTighterThanAnythingElse() {
        #expect(ChatBlockSpacing.blockTopInset(
            previous: .toolCall,
            current: .toolCall,
            dimensions: dimensions
        ) == dimensions.toolCallSpacing)
        #expect(ChatBlockSpacing.rowTopInset(
            previous: .toolCall,
            current: .toolCall,
            dimensions: dimensions
        ) == dimensions.toolCallSpacing)
        #expect(dimensions.toolCallSpacing < dimensions.messageBlockSpacing)
        #expect(dimensions.messageBlockSpacing < dimensions.messageSpacing)
    }

    @Test func aToolCallMeetingAnythingElseKeepsTheFullGap() {
        for (previous, current) in [
            (ChatBlockSpacing.Kind.toolCall, ChatBlockSpacing.Kind.other),
            (.other, .toolCall),
            (.other, .other)
        ] {
            #expect(ChatBlockSpacing.blockTopInset(
                previous: previous,
                current: current,
                dimensions: dimensions
            ) == dimensions.messageBlockSpacing)
            #expect(ChatBlockSpacing.rowTopInset(
                previous: previous,
                current: current,
                dimensions: dimensions
            ) == dimensions.messageSpacing)
        }
    }

    @Test func theFirstBlockOfAMessageTakesNoInset() {
        #expect(ChatBlockSpacing.blockTopInset(
            previous: nil,
            current: .other,
            dimensions: dimensions
        ) == 0)
    }

    @Test func theFirstRowTakesTheListsOwnInset() {
        #expect(ChatBlockSpacing.rowTopInset(
            previous: nil,
            current: .other,
            dimensions: dimensions
        ) == dimensions.verticalPadding)
    }

    @Test func aRunOfToolCallMessagesCollapsesWhileTheProseAroundItDoesNot() {
        let insets = ChatBlockSpacing.rowTopInsets(
            [
                message(id: "a", role: .user, blocks: [.markdown("go")]),
                message(id: "b", role: .assistant, blocks: [toolCall(id: "1")]),
                message(id: "c", role: .assistant, blocks: [toolCall(id: "2")]),
                message(id: "d", role: .assistant, blocks: [.markdown("done")])
            ],
            dimensions: dimensions
        )
        #expect(insets == [
            dimensions.verticalPadding,
            dimensions.messageSpacing,
            dimensions.toolCallSpacing,
            dimensions.messageSpacing
        ])
    }

    /// The pending dock draws a stalled call instead of the row, so the block
    /// is not on screen to space anything against.
    @Test func aBlockTheDockDrawsIsSkipped() {
        let blocks: [ChatBlock] = [toolCall(id: "1"), toolCall(id: "2"), .markdown("done")]
        let insets = ChatBlockSpacing.blockTopInsets(
            blocks,
            hiddenToolUseIDs: ["2"],
            dimensions: dimensions
        )
        #expect(insets == [0, 0, dimensions.messageBlockSpacing])
        #expect(ChatBlockSpacing.lastRenderedKind(blocks, hiddenToolUseIDs: ["2"]) == .other)
        #expect(ChatBlockSpacing.lastRenderedKind(
            [toolCall(id: "1"), toolCall(id: "2")],
            hiddenToolUseIDs: ["2"]
        ) == .toolCall)
        #expect(ChatBlockSpacing.lastRenderedKind(
            [toolCall(id: "1")],
            hiddenToolUseIDs: ["1"]
        ) == nil)
    }

    @Test func theFirstRenderedBlockStillTakesNoInset() {
        let insets = ChatBlockSpacing.blockTopInsets(
            [toolCall(id: "1"), .markdown("done")],
            hiddenToolUseIDs: ["1"],
            dimensions: dimensions
        )
        #expect(insets == [0, 0])
    }

    /// A tool result ends the assistant's run, so text streamed after a call
    /// lands in a message of its own and must already sit a message apart.
    @Test func theStreamTakesTheGapItWillHaveOnceItSettles() {
        #expect(ChatBlockSpacing.streamingTopInset(
            previous: .toolCall,
            dimensions: dimensions
        ) == dimensions.messageSpacing)
        #expect(ChatBlockSpacing.streamingTopInset(
            previous: .other,
            dimensions: dimensions
        ) == dimensions.messageBlockSpacing)
    }

    @Test func theStandaloneStreamPaysNothingOfItsOwn() {
        #expect(ChatBlockSpacing.streamingTopInset(previous: nil, dimensions: dimensions) == 0)
    }
}
