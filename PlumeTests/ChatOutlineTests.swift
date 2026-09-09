import Foundation
import Testing
@testable import Plume

/// The outline the minimap draws: what the user said or was asked, carrying
/// its opening line, with runs of agent output collapsed into weighted areas.
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

    @Test func userInputSeparatesRunsOfAgentOutput() {
        let result = outline([
            message("a", .user, [.markdown("Ask something.")]),
            message("b", .assistant, [.markdown("First.\n\nSecond.\n\nThird.")]),
            message("c", .user, [.markdown("Ask again.")])
        ])

        #expect(result.entries.map(\.kind) == [
            .prompt("Ask something."), .response, .prompt("Ask again.")
        ])
    }

    @Test func aRunOfAgentMessagesCollapsesIntoOneArea() {
        // Several assistant messages with no user input between them are one
        // stretch to scroll past, however the transcript split them.
        let result = outline([
            message("a", .user, [.markdown("Go.")]),
            message("b", .assistant, [toolCall("t1")]),
            message("c", .assistant, [.markdown("Thinking out loud.")]),
            message("d", .assistant, [toolCall("t2")])
        ])

        #expect(result.entries.map(\.kind) == [.prompt("Go."), .response])
    }

    @Test func aPromptCarriesItsOpeningLine() {
        let result = outline([
            message("a", .user, [.markdown("Add a minimap\nand make it nice.")])
        ])

        #expect(result.entries.first?.kind == .prompt("Add a minimap"))
    }

    @Test func theAgentAndTheTranscriptAreOneArea() {
        // A notice is the transcript's own voice, not the user's, so it joins
        // the agent's mass rather than anchoring anything.
        let result = outline([
            message("a", .assistant, [.markdown("A reply.")]),
            message("b", .notice, [.notice(ChatNotice(kind: .info, title: "Note", detail: nil))])
        ])

        #expect(result.entries.map(\.kind) == [.response])
    }

    @Test func anEntryScrollsToItsFirstPiece() {
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

        #expect(result.entries.map(\.kind) == [.prompt("Go.")])
    }

    @Test func anEmptyConversationHasNoEntries() {
        #expect(outline([]).isEmpty)
        // Nothing divides by the total, whatever it holds.
        #expect(ChatOutline().totalWeight >= 1)
    }

    // MARK: - What anchors

    /// The user's role covers a lot the user never typed, and anchoring on
    /// any of it would put a landmark where nothing was said.
    @Test(arguments: [
        InjectedContent.interrupted,
        .commandCaveat,
        .slashCommand(name: "/rename", arguments: "chat-minimap"),
        .commandOutput(command: "/context"),
        .taskNotification,
        .systemNote,
        .compactSummary,
        .skill(name: "worktrees")
    ])
    func injectedContentIsNotAPrompt(_ content: InjectedContent) {
        let result = outline([
            message("a", .user, [.injected(content, text: "Some text.")])
        ])

        #expect(result.entries.map(\.kind) == [.response])
    }

    @Test func whatTheUserActuallyTypedIsAPrompt() {
        let result = outline([
            message("a", .user, [.injected(.userMessage, text: "Real words.")])
        ])

        #expect(result.entries.map(\.kind) == [.prompt("Real words.")])
    }

    @Test func aQuestionAnchorsLikeAPrompt() throws {
        // The agent asked it, but answering is the user's turn, so it is a
        // landmark in the same way a prompt is.
        var call = ToolCall(
            id: "q1",
            name: "AskUserQuestion",
            summary: ToolCallSummary(name: "AskUserQuestion"),
            input: .json("{}")
        )
        call.interactive = .questions([
            InteractiveToolPayload.AskedQuestion(
                header: "Approach",
                question: "Which approach?",
                multiSelect: false,
                options: []
            )
        ])
        let result = outline([message("a", .assistant, [.toolCall(call)])])

        #expect(result.entries.map(\.kind) == [.question("Which approach?")])
    }

    @Test func aMultiPiecePromptIsOneEntry() throws {
        // A long prompt splits into several pieces, but the user said it
        // once, so the map marks it once.
        let long = String(repeating: "Some words to wrap. ", count: 30)
        let result = outline([
            message("a", .user, [.markdown("\(long)\n\n\(long)\n\n\(long)")])
        ])

        #expect(result.entries.count == 1)
        let entry = try #require(result.entries.first)
        #expect(entry.kind.isUserInput)
        // It still covers every piece it split into, so scrolling through
        // any of them keeps the entry marked.
        #expect(entry.pieceIDs.count > 1)
    }

    @Test func anEntryScrollsToWhereItStarts() throws {
        let long = String(repeating: "Some words to wrap. ", count: 30)
        let all = pieces([message("a", .user, [.markdown("\(long)\n\n\(long)")])])
        let result = ChatOutlineBuilder.outline(from: all)

        #expect(result.entries.first?.id == all.first?.id)
    }

    // MARK: - Weight

    @Test func weightGrowsWithLengthButNotProportionally() {
        // A response ten times longer must read as bigger, without owning
        // the whole map.
        let small = ChatOutlineBuilder.compress(100)
        let large = ChatOutlineBuilder.compress(1_000)
        let huge = ChatOutlineBuilder.compress(10_000)

        #expect(small < large)
        #expect(large < huge)
        #expect(huge / small < 10)
    }

    @Test func alongerReplyOutweighsAShorterOne() throws {
        let brief = outline([message("a", .assistant, [.markdown("Brief.")])])
        let long = outline([
            message("a", .assistant, [
                .markdown(String(repeating: "A sentence of some length. ", count: 40))
            ])
        ])

        let short = try #require(brief.entries.first?.weight)
        let tall = try #require(long.entries.first?.weight)
        #expect(tall > short)
    }

    @Test func everyEntryKeepsAClickableFloor() throws {
        // An area that draws almost nothing still has to be big enough to
        // hit. A rule carries no text at all.
        let result = outline([
            message("a", .user, [.markdown("Go.")]),
            message("b", .assistant, [.markdown("---")])
        ])

        let area = try #require(result.entries.last)
        #expect(area.kind == .response)
        #expect(area.weight == ChatOutlineBuilder.minimumWeight)
        #expect(result.entries.allSatisfy { $0.weight >= ChatOutlineBuilder.minimumWeight })
    }

    @Test func aToolCallWeighsItsRowRatherThanItsText() throws {
        // A collapsed call draws one short row whatever it contains, so its
        // input length says nothing about the room it takes.
        let result = outline([message("a", .assistant, [toolCall("t1"), toolCall("t2")])])

        let weight = try #require(result.entries.first?.weight)
        #expect(weight == ChatOutlineBuilder.toolCallWeight * 2)
    }

    @Test func anAreasPiecesSumIntoOneWeight() throws {
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
