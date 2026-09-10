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

    @Test func aPlanAnchorsLikeAPrompt() throws {
        // The agent wrote it, but approving it is the user's turn, so it is
        // a landmark in the same way a question is.
        var call = ToolCall(
            id: "p1",
            name: "ExitPlanMode",
            summary: ToolCallSummary(name: "ExitPlanMode"),
            input: .json("{}")
        )
        call.interactive = .plan(markdown: "# Rework the minimap\n\nSome detail.", filePath: nil)
        let result = outline([message("a", .assistant, [.toolCall(call)])])

        #expect(result.entries.map(\.kind) == [.plan("Rework the minimap")])
    }

    @Test func onlyWhatTheUserDidNotWriteIsMarked() {
        // A mark against every one of the user's own messages would be
        // noise; the icons are there to pick out what is not one.
        #expect(ChatOutline.Kind.prompt("Hi").symbol == nil)
        #expect(ChatOutline.Kind.response.symbol == nil)
        #expect(ChatOutline.Kind.question("Which?").symbol != nil)
        #expect(ChatOutline.Kind.plan("A plan").symbol != nil)
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

    // MARK: - Where the reader is

    @Test func positionRunsFromTopToBottom() throws {
        let result = outline([
            message("a", .user, [.markdown("First.")]),
            message("b", .assistant, [.markdown("Reply.")]),
            message("c", .user, [.markdown("Last.")])
        ])

        let first = try #require(result.entries.first)
        let last = try #require(result.entries.last)
        let top = try #require(result.position(of: first.pieceIDs))
        let bottom = try #require(result.position(of: last.pieceIDs))

        #expect(top < bottom)
        #expect(top >= 0)
        #expect(bottom <= 1)
    }

    @Test func severalVisibleEntriesAverage() throws {
        let result = outline([
            message("a", .user, [.markdown("First.")]),
            message("b", .assistant, [.markdown("Reply.")]),
            message("c", .user, [.markdown("Last.")])
        ])

        let first = try #require(result.entries.first)
        let last = try #require(result.entries.last)
        let top = try #require(result.position(of: first.pieceIDs))
        let bottom = try #require(result.position(of: last.pieceIDs))
        let both = try #require(result.position(of: first.pieceIDs.union(last.pieceIDs)))

        #expect(both > top)
        #expect(both < bottom)
    }

    @Test func nothingVisibleHasNoPosition() {
        let result = outline([message("a", .user, [.markdown("Only.")])])

        #expect(result.position(of: []) == nil)
        #expect(result.position(of: ["not-a-piece"]) == nil)
        #expect(ChatOutline().position(of: ["anything"]) == nil)
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
        // input length says nothing about the room it takes. Two identical
        // calls therefore weigh the same as two of any other call, however
        // much text they carry.
        let brief = outline([message("a", .assistant, [toolCall("t1"), toolCall("t2")])])
        var verbose = ToolCall(
            id: "t3",
            name: "Read",
            summary: ToolCallSummary(name: "Read", detail: "a file"),
            input: .json(String(repeating: "x", count: 5_000))
        )
        verbose.result = String(repeating: "y", count: 5_000)
        let wordy = outline([message("a", .assistant, [toolCall("t1"), .toolCall(verbose)])])

        #expect(try #require(brief.entries.first?.weight) == #require(wordy.entries.first?.weight))
    }

    @Test func aPromptOutweighsATypicalResponse() throws {
        // The map is for finding prompts, so a response reads as the
        // distance between two of them rather than competing with them.
        let result = outline([
            message("a", .user, [.markdown("Ask.")]),
            message("b", .assistant, [.markdown(String(repeating: "A reply. ", count: 20))])
        ])

        let prompt = try #require(result.entries.first)
        let response = try #require(result.entries.last)
        #expect(prompt.weight > response.weight)
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

/// How the pointer's height down the minimap's rail maps to how far through
/// the conversation the map has travelled.
@MainActor
struct ChatMinimapEasingTests {
    @Test func theEndsArePinned() {
        #expect(ChatMinimap.eased(0) == 0)
        #expect(ChatMinimap.eased(ChatMinimap.liveRange.lowerBound) == 0)
        #expect(ChatMinimap.eased(ChatMinimap.liveRange.upperBound) == 1)
        #expect(ChatMinimap.eased(1) == 1)
    }

    @Test func theMiddleOfTheRailIsTheMiddleOfTheConversation() {
        #expect(abs(ChatMinimap.eased(0.5) - 0.5) < 0.0001)
    }

    @Test func travelOnlyEverGrows() {
        var previous = ChatMinimap.eased(0)
        for step in 1...100 {
            let next = ChatMinimap.eased(CGFloat(step) / 100)
            #expect(next >= previous)
            previous = next
        }
    }

    /// The point of the curve: the same movement of the hand covers more
    /// ground in the middle than at either end.
    @Test func theMiddleIsFasterThanTheEnds() {
        let atEnd = ChatMinimap.eased(0.20) - ChatMinimap.eased(0.15)
        let atMiddle = ChatMinimap.eased(0.55) - ChatMinimap.eased(0.50)
        #expect(atMiddle > atEnd * 2)
    }
}
