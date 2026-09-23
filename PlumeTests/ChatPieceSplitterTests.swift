import Foundation
import Testing
@testable import Plume

@MainActor
struct ChatPieceSplitterTests {
    private let dimensions = Dimensions(bodySize: 13)

    private func pieces(
        _ messages: [ChatMessage],
        status: TaskStatus = .awaitingReply,
        hidden: Set<String> = [],
        streaming: ChatStreamHandoff.Overlay = .init()
    ) -> [ChatPiece] {
        ChatPieceSplitter.pieces(
            for: messages,
            status: status,
            hiddenToolUseIDs: hidden,
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
        .toolCall(ToolCall(id: id, name: "Read", summary: ToolCallSummary(name: "Read", detail: "a file"), input: .json("{}")))
    }

    // MARK: - Identity

    @Test func everyBlockBecomesItsOwnPiece() {
        let result = pieces([message("m", .assistant, [
            .markdown("First paragraph.\n\nSecond paragraph."),
            toolCall("t1"),
            .thinking("hm")
        ])])
        #expect(result.map(\.id) == ["m/0/0", "m/0/1", "m/1", "m/2"])
        #expect(result.allSatisfy { $0.messageID == "m" })
    }

    /// A list takes one piece per item, so the two items below are the last
    /// two pieces rather than one segment holding both.
    @Test func aMarkdownBlockSplitsIntoOnePiecePerSubBlock() {
        let result = pieces([message("m", .assistant, [
            .markdown("# Title\n\nBody text.\n\n- one\n- two")
        ])])
        #expect(result.map(\.id) == ["m/0/0", "m/0/1", "m/0/2/0", "m/0/2/1"])
        guard case .markdown(.heading(1, "Title"), 0) = result[0].content else {
            Issue.record("expected a heading piece, got \(result[0].content)")
            return
        }
        let items = result.compactMap { piece -> [String]? in
            guard case .listSegment(let list) = piece.content else { return nil }
            return list.items.map(\.text)
        }
        #expect(items == [["one"], ["two"]])
    }

    /// The dock draws a stalled call instead, so it renders nothing here and
    /// does not space what follows it. The blocks around it keep their ids.
    @Test func aHiddenToolCallIsOmittedWithoutShiftingIds() {
        let blocks: [ChatBlock] = [toolCall("t1"), toolCall("t2"), .markdown("done")]
        let visible = pieces([message("m", .assistant, blocks)])
        #expect(visible.map(\.id) == ["m/0", "m/1", "m/2/0"])

        let hidden = pieces([message("m", .assistant, blocks)], hidden: ["t2"])
        #expect(hidden.map(\.id) == ["m/0", "m/2/0"])
        // The prose still follows a tool call, so it keeps the full gap; the
        // hidden call in between neither takes space nor closes one up.
        #expect(hidden[1].topInset == dimensions.messageBlockSpacing)
    }

    @Test func aToolResultLandingChangesOnlyItsOwnPiece() {
        let before = pieces([message("m", .assistant, [.markdown("Reading."), toolCall("t1")])])
        var call = ToolCall(id: "t1", name: "Read", summary: ToolCallSummary(name: "Read", detail: "a file"), input: .json("{}"))
        call.result = "contents"
        let after = pieces([message("m", .assistant, [.markdown("Reading."), .toolCall(call)])])

        #expect(before.map(\.id) == after.map(\.id))
        #expect(before[0] == after[0])
        #expect(before[1] != after[1])
    }

    @Test func appendingKeepsEveryEarlierPieceIntact() {
        let first = pieces([message("m", .assistant, [.markdown("One.")])])
        let second = pieces([message("m", .assistant, [.markdown("One."), toolCall("t1")])])

        #expect(first[0].segment == .single)
        #expect(second[0].segment == .first)
        #expect(second[1].segment == .last)
        #expect(first[0].id == second[0].id)
        #expect(first[0].topInset == second[0].topInset)
        #expect(first[0].content == second[0].content)
    }

    /// Ids must be unique across every kind of piece: a duplicate id in a
    /// `ForEach` was found to thrash SwiftUI's lazy layout into a hang, with
    /// nothing visibly wrong (`docs/chat-list.md`).
    ///
    /// What keeps them unique is the depth of the `/`-separated path, not the
    /// kind: one component past the message id for a whole block, two for a
    /// markdown block inside it, three for a segment of a split one. Every
    /// component is an `Int`, so a shorter path can never equal a longer one.
    @Test func everyPieceIDIsUniqueAcrossKinds() {
        let longList = (1...40).map { "- item \($0)" }.joined(separator: "\n")
        let result = pieces(
            [
                message("a", .assistant, [
                    .markdown("One.\n\nTwo.\n\nThree."),
                    .thinking("Considering."),
                    toolCall("t1"),
                    .image(ChatImage(mediaType: "image/png", base64: "abc")),
                    .markdown("Intro.\n\n" + longList)
                ]),
                message("b", .user, [
                    .injected(.slashCommand(name: "clear"), text: "/clear"),
                    .markdown("go")
                ]),
                message("c", .notice, [
                    .notice(ChatNotice(kind: .compaction, title: "Compacted", detail: nil))
                ]),
                message("d", .assistant, [.markdown("Nearly done.")])
            ],
            status: .working,
            streaming: ChatStreamHandoff.Overlay(
                thinking: "Thinking out loud.",
                text: "Settled block.\n\nStill arriving"
            )
        )
        let ids = result.map(\ChatPiece.id)
        #expect(Set(ids).count == ids.count)
        // The kinds this transcript is meant to cover, so a piece kind added
        // later without an id of its own fails here rather than silently
        // going untested.
        let kinds = Set(result.map(\ChatPiece.kindName))
        #expect(kinds.isSuperset(of: [
            "thinking", "toolCall", "injected", "notice", "image", "working", "list"
        ]))
        #expect(kinds.contains { $0.hasPrefix("markdown.") })
    }

    // MARK: - Segments

    @Test func aMessageOfOnePieceIsWholeAndOneOfSeveralIsJoined() {
        #expect(pieces([message("m", .user, [.markdown("go")])]).map(\.segment) == [.single])
        #expect(pieces([message("m", .user, [.markdown("a\n\nb\n\nc")])]).map(\.segment)
            == [.first, .middle, .last])
    }

    @Test func theTurnInFlightJoinsTheLastMessagesGroup() {
        let result = pieces(
            [message("m", .assistant, [.markdown("Working on it.")])],
            status: .working,
            streaming: ChatStreamHandoff.Overlay(text: "Nearly there.")
        )
        #expect(result.map(\.id) == ["m/0/0", "stream/0", "working"])
        #expect(result.map(\.segment) == [.first, .middle, .last])
        #expect(result.allSatisfy { $0.messageID == "m" || $0.messageID == "stream" })
    }

    /// A turn that has not produced an assistant message yet stands alone,
    /// taking the gap the message it becomes will have.
    @Test func aStreamAfterAUserMessageStandsOnItsOwn() {
        let result = pieces(
            [message("m", .user, [.markdown("go")])],
            streaming: ChatStreamHandoff.Overlay(text: "On it.")
        )
        #expect(result.map(\.id) == ["m/0/0", "stream/0"])
        #expect(result[1].segment == .single)
        #expect(result[1].topInset == dimensions.messageSpacing)
    }

    @Test func onlyTheNewestAssistantMessageWearsTheAttentionWash() {
        let result = pieces(
            [
                message("a", .assistant, [.markdown("done")]),
                message("b", .user, [.markdown("go")]),
                message("c", .assistant, [.markdown("Should I proceed?")])
            ],
            status: .permissionNeeded
        )
        #expect(result.map(\.wash) == [.none, .bubble, .attention])
    }

    /// Another agent's message is somebody speaking, so it takes a bubble —
    /// on the leading edge, titled, with its body split as markdown.
    @Test func anAgentMessageTakesItsOwnBubble() {
        let text = """
        Another Claude session sent a message:
        <cross-session-message from-name="plume-8b">
        First.

        Second.
        </cross-session-message>

        Boilerplate the reader never sees.
        """
        let result = pieces([message("m", .user, [.injected(.agentMessage(name: "plume-8b"), text: text)])])
        #expect(result.allSatisfy { $0.wash == .agentBubble })
        #expect(result.first?.content == .agentMessageTitle(name: "plume-8b"))
        #expect(result.count == 3)
        #expect(Set(result.map(\.id)).count == result.count)
        #expect(result.first?.segment == .first)
        #expect(result.last?.segment == .last)
    }

    /// An injected line is not the user speaking, so it skips the bubble.
    @Test func anInjectedOnlyUserMessageSkipsTheBubble() {
        let result = pieces([message("m", .user, [.injected(.slashCommand(name: "clear"), text: "/clear")])])
        #expect(result.map(\.wash) == [ChatPiece.Wash.none])
    }

    // MARK: - Oversized blocks

    private func codeMessage(lines count: Int) -> ChatMessage {
        let code = (1...count).map { "let value\($0) = \($0)" }.joined(separator: "\n")
        return message("m", .assistant, [.markdown("```swift\n\(code)\n```")])
    }

    /// A code block is one artifact: it stays one piece however long it is,
    /// and the view scrolls it instead.
    @Test func aLongCodeBlockStaysOnePiece() {
        let result = pieces([codeMessage(lines: 400)])
        #expect(result.map(\.id) == ["m/0/0"])
        guard case .codeSegment(let segment) = result[0].content else {
            Issue.record("expected a code piece")
            return
        }
        #expect(segment.language == "swift")
        #expect(segment.code.components(separatedBy: "\n").count == 400)
    }

    @Test func aMermaidFenceIsOnePiece() {
        let body = (1...60).map { "  A --> B\($0)" }.joined(separator: "\n")
        let result = pieces([message("m", .assistant, [.markdown("```mermaid\ngraph TD\n\(body)\n```")])])
        #expect(result.count == 1)
        guard case .codeSegment(let segment) = result[0].content else {
            Issue.record("expected a code piece")
            return
        }
        #expect(segment.isMermaid)
    }

    @Test func aLongNumberedListSplitsAndKeepsCounting() {
        let items = (1...30).map { "\($0). Item number \($0)" }.joined(separator: "\n")
        let result = pieces([message("m", .assistant, [.markdown(items)])])
        #expect(result.count > 1)

        let segments: [ListSegment] = result.compactMap {
            if case .listSegment(let segment) = $0.content { return segment }
            return nil
        }
        #expect(segments.count == result.count)
        let listItems = segments.flatMap(\.items)
        #expect(listItems.count == 30)
        #expect(listItems.map(\.number) == Array(1...30))
        #expect(listItems.allSatisfy { $0.depth == 0 })
        #expect(result.dropFirst().allSatisfy { $0.topInset == ChatBlockSpacing.listSegmentSpacing })
        // Segments of equal length, so a list just over the ceiling does not
        // end on a segment of one item.
        let lengths = Set(segments.map(\.items.count))
        #expect(lengths.count <= 2)
        #expect((lengths.max() ?? 0) - (lengths.min() ?? 0) <= 1)
    }

    /// Every item carries its own depth and number, so a piece cut away from
    /// the items around it still indents and numbers itself correctly.
    @Test func aSplitNestedListKeepsEachItemsDepthAndNumber() {
        let source = """
        1. one
           - inner a
           - inner b
        2. two
           1. deep one
           2. deep two
        3. three
        """
        let result = pieces([message("m", .assistant, [.markdown(source)])])
        let segments: [ListSegment] = result.compactMap {
            if case .listSegment(let segment) = $0.content { return segment }
            return nil
        }
        #expect(segments.count == 7)
        #expect(segments.allSatisfy { $0.items.count == 1 })
        let listItems = segments.flatMap(\.items)
        #expect(listItems.map(\.depth) == [0, 1, 1, 0, 1, 1, 0])
        #expect(listItems.map(\.number) == [1, nil, nil, 2, 1, 2, 3])
    }

    /// Segments would size their columns independently and the join would show.
    @Test func aTableIsNeverSplit() {
        let rows = (1...60).map { "| row \($0) | value \($0) |" }.joined(separator: "\n")
        let result = pieces([message("m", .assistant, [.markdown("| a | b |\n| --- | --- |\n\(rows)")])])
        #expect(result.count == 1)
        guard case .markdown(.table, 0) = result[0].content else {
            Issue.record("expected a table piece, got \(result[0].content)")
            return
        }
    }

    /// A quote takes one piece per paragraph however short it is, and every
    /// piece after the first continues the bar so the split reads as one
    /// quote rather than several.
    @Test func aQuoteSplitsByParagraphAndKeepsItsBar() {
        let result = pieces([message("m", .assistant, [
            .markdown("> First thought.\n>\n> Second thought.\n>\n> Third thought.")
        ])])
        let quotes = result.compactMap { piece -> (String, Bool)? in
            guard case .markdown(.quote(let text, let continues), _) = piece.content else { return nil }
            return (text, continues)
        }
        #expect(quotes.map(\.0) == ["First thought.", "Second thought.", "Third thought."])
        #expect(quotes.map(\.1) == [false, true, true])
        // The gap rides inside the bar, so the list must not pay it again.
        #expect(result.dropFirst().allSatisfy { $0.topInset == 0 })
    }

    @Test func aOneParagraphQuoteStaysOnePiece() {
        let result = pieces([message("m", .assistant, [.markdown("> A brief aside.")])])
        #expect(result.count == 1)
        guard case .markdown(.quote(_, let continues), _) = result[0].content else {
            Issue.record("expected a quote piece, got \(result[0].kindName)")
            return
        }
        #expect(!continues)
    }

    /// Splitting must not drop or duplicate any of the source's paragraphs.
    @Test func aSplitProseRunKeepsEveryParagraph() {
        let source = (1...5).map { "Para \($0)." }.joined(separator: "\n\n")
        let parts = ChatPieceMetrics.proseParagraphs(source)
        #expect(parts == ["Para 1.", "Para 2.", "Para 3.", "Para 4.", "Para 5."])
    }

    // MARK: - Spacing

    @Test func theFirstPieceOfTheListPaysTheListsOwnInset() {
        let result = pieces([message("m", .assistant, [.markdown("hi")])])
        #expect(result[0].topInset == dimensions.verticalPadding)
    }

    @Test func messagesSpaceAsTheirRowsDidAndToolCallRunsStillCollapse() {
        let messages = [
            message("a", .user, [.markdown("go")]),
            message("b", .assistant, [toolCall("1")]),
            message("c", .assistant, [toolCall("2")]),
            message("d", .assistant, [.markdown("done")])
        ]
        let expected = ChatBlockSpacing.rowTopInsets(messages, dimensions: dimensions)
        #expect(pieces(messages).map(\.topInset) == expected)
    }

    @Test func blocksWithinAMessageSpaceByRole() {
        let user = pieces([message("m", .user, [.markdown("a"), .markdown("b")])])
        #expect(user[1].topInset == ChatBlockSpacing.userBlockSpacing)

        let notice = pieces([message("m", .notice, [
            .notice(ChatNotice(kind: .info, title: "one", detail: nil)),
            .notice(ChatNotice(kind: .info, title: "two", detail: nil))
        ])])
        #expect(notice[1].topInset == ChatBlockSpacing.noticeBlockSpacing)

        let assistant = pieces([message("m", .assistant, [toolCall("1"), toolCall("2")])])
        #expect(assistant[1].topInset == dimensions.toolCallSpacing)
    }

    /// A notice message pays a little above its first block and below its
    /// last, which one row used to draw as its own vertical padding.
    @Test func aNoticeMessagePaysItsOwnPaddingAtTheEdges() {
        let result = pieces([message("m", .notice, [
            .notice(ChatNotice(kind: .info, title: "one", detail: nil)),
            .notice(ChatNotice(kind: .info, title: "two", detail: nil))
        ])])
        #expect(result[0].topInset
            == dimensions.verticalPadding + ChatBlockSpacing.noticeVerticalPadding)
        #expect(result[0].bottomInset == 0)
        #expect(result[1].bottomInset == ChatBlockSpacing.noticeVerticalPadding)
    }

    @Test func aNonInitialHeadingKeepsTheSpaceItOpensASectionWith() {
        let result = pieces([message("m", .assistant, [.markdown("Body.\n\n## Section\n\nMore.")])])
        #expect(result[1].topInset
            == dimensions.blockSpacing + dimensions.headingTopSpacing(level: 2))
        #expect(result[2].topInset == dimensions.blockSpacing)
    }

    @Test func theWorkingIndicatorSitsWellBelowWhateverPrecedesIt() {
        let following = pieces(
            [message("m", .assistant, [.markdown("hi")])],
            status: .working
        )
        #expect(following.last?.topInset == dimensions.workingIndicatorSpacing)
        #expect(dimensions.workingIndicatorSpacing >= dimensions.messageSpacing)

        let alone = pieces([message("m", .assistant, [])], status: .working)
        #expect(alone.map(\.id) == ["working"])
        #expect(alone[0].topInset == dimensions.verticalPadding)
    }

    /// An empty lazy item is exactly the near-zero height the ceiling exists
    /// to keep away from, and real transcripts carry thinking blocks with no
    /// text.
    @Test func aBlockThatDrawsNothingTakesNoItem() {
        let result = pieces([message("m", .assistant, [
            .thinking("   \n "),
            .markdown("done")
        ])])
        #expect(result.map(\.id) == ["m/1/0"])
        #expect(result[0].topInset == dimensions.verticalPadding)
    }

    /// A turn that has not produced an assistant message yet still shows it
    /// is working, as the reply's own stand-in rather than inside the user's
    /// bubble.
    @Test func theWorkingIndicatorNeverJoinsAUserMessage() {
        let result = pieces([message("m", .user, [.markdown("go")])], status: .working)
        #expect(result.map(\.id) == ["m/0/0", "working"])
        #expect(result.map(\.segment) == [.single, .single])
        #expect(result[1].wash == .none)
        #expect(result[1].topInset == dimensions.messageSpacing)
    }

    @Test func theWorkingIndicatorFollowsAStreamAfterAUserMessage() {
        let result = pieces(
            [message("m", .user, [.markdown("go")])],
            status: .working,
            streaming: ChatStreamHandoff.Overlay(text: "On it.")
        )
        #expect(result.map(\.id) == ["m/0/0", "stream/0", "working"])
        #expect(result.map(\.segment) == [.single, .first, .last])
        #expect(result[2].topInset == dimensions.workingIndicatorSpacing)
    }

    @Test func theStreamTakesTheGapItWillHaveOnceItSettles() {
        let afterProse = pieces(
            [message("m", .assistant, [.markdown("hi")])],
            streaming: ChatStreamHandoff.Overlay(text: "more")
        )
        #expect(afterProse[1].topInset == dimensions.messageBlockSpacing)

        let afterCall = pieces(
            [message("m", .assistant, [toolCall("1")])],
            streaming: ChatStreamHandoff.Overlay(text: "more")
        )
        #expect(afterCall[1].topInset == dimensions.messageSpacing)
    }

    // MARK: - The streaming overlay

    /// Everything above the block still arriving is settled markdown, so a
    /// long reply mid-stream is as bounded as the transcript it becomes.
    @Test func onlyTheBlockStillArrivingStaysLive() {
        let result = pieces(
            [message("m", .user, [.markdown("go")])],
            streaming: ChatStreamHandoff.Overlay(text: "Settled paragraph.\n\nStill arri")
        )
        #expect(result.map(\.id) == ["m/0/0", "stream/0", "stream/1"])
        guard case .markdown(.paragraph("Settled paragraph."), 0) = result[1].content else {
            Issue.record("expected a settled paragraph, got \(result[1].content)")
            return
        }
        #expect(!result[1].isArriving)
        #expect(result[2].isArriving)
        #expect(result[2].topInset == dimensions.blockSpacing)
        // Each keeps its own source, which is what lets a block go on typing
        // after it stops growing.
        #expect(result[1].streamSource == "Settled paragraph.")
        #expect(result[2].streamSource == "Still arri")
    }

    /// The point of keying the arriving block by its index: the piece keeps
    /// its identity when the block completes, so the view drawing it keeps
    /// the reveal's progress instead of snapping to the finished text.
    @Test func aBlockKeepsItsIDWhenItStopsArriving() {
        let arriving = pieces(
            [message("m", .user, [.markdown("go")])],
            streaming: ChatStreamHandoff.Overlay(text: "First one.\n\nSecond stil")
        )
        let settled = pieces(
            [message("m", .user, [.markdown("go")])],
            streaming: ChatStreamHandoff.Overlay(text: "First one.\n\nSecond still here.\n\nThird")
        )
        #expect(arriving.map(\.id) == ["m/0/0", "stream/0", "stream/1"])
        #expect(settled.map(\.id) == ["m/0/0", "stream/0", "stream/1", "stream/2"])
        #expect(arriving[2].isArriving)
        #expect(!settled[2].isArriving)
        #expect(settled[2].streamSource == "Second still here.")
    }

    @Test func liveThinkingStaysOnePiece() {
        let result = pieces(
            [message("m", .user, [.markdown("go")])],
            streaming: ChatStreamHandoff.Overlay(thinking: "considering", text: "Hello")
        )
        #expect(result.map(\.id) == ["m/0/0", "stream/thinking", "stream/0"])
        #expect(result[1].content == .streaming(ChatStreamHandoff.Overlay(thinking: "considering")))
        #expect(result[2].topInset == ChatBlockSpacing.streamingBlockSpacing)
    }

    // MARK: - The cache

    @Test func theCacheParsesOnlyWhatChanged() {
        let cache = ChatPieceCache()
        let messages = [
            message("a", .assistant, [.markdown("One.")]),
            message("b", .assistant, [.markdown("Two.")])
        ]
        let first = cache.pieces(
            for: messages,
            status: .awaitingReply,
            hiddenToolUseIDs: [],
            streaming: .init(),
            dimensions: dimensions
        )
        #expect(cache.parseCount == 2)

        let again = cache.pieces(
            for: messages,
            status: .awaitingReply,
            hiddenToolUseIDs: [],
            streaming: .init(),
            dimensions: dimensions
        )
        #expect(cache.parseCount == 2)
        #expect(first == again)

        _ = cache.pieces(
            for: [messages[0], message("b", .assistant, [.markdown("Two, revised.")])],
            status: .awaitingReply,
            hiddenToolUseIDs: [],
            streaming: .init(),
            dimensions: dimensions
        )
        #expect(cache.parseCount == 3)
    }

    /// Keyed by markdown source and pruned to what the messages hold, so the
    /// cache never outgrows the transcript on screen.
    @Test func theCacheForgetsWhatTheTranscriptNoLongerHolds() {
        let cache = ChatPieceCache()
        func build(_ text: String) {
            _ = cache.pieces(
                for: [message("a", .assistant, [.markdown(text)])],
                status: .awaitingReply,
                hiddenToolUseIDs: [],
                streaming: .init(),
                dimensions: dimensions
            )
        }
        build("One.")
        build("Two.")
        build("One.")
        #expect(cache.parseCount == 3)
    }

    // MARK: - Copy source

    /// A block the splitter left whole copies the lines it was parsed from,
    /// not a re-rendering of them.
    @Test func aWholeBlockKeepsItsOwnSource() {
        let table = "| a | b |\n| --- | --- |\n| 1 | 2 |"
        let result = pieces([message("m", .assistant, [.markdown("Intro.\n\n" + table)])])
        #expect(result.count == 2)
        #expect(result[0].copySource == "Intro.")
        #expect(result[1].copySource == table)
        #expect(result[1].tableCopySource == table)
    }

    /// A split block has no lines of its own, so each segment is written back
    /// from its structure.
    @Test func aSplitListSegmentCopiesJustItsOwnItem() {
        let result = pieces([message("m", .assistant, [.markdown("1. one\n2. two")])])
        #expect(result.map(\.copySource) == ["1. one", "2. two"])
    }

    /// Only a table offers its own button. Prose is selectable and a code
    /// block carries `CodeBlockCopyButton` already.
    @Test func onlyATableOffersItsOwnCopyButton() {
        let result = pieces([message("m", .assistant, [
            .markdown("Text.\n\n```swift\nlet x = 1\n```")
        ])])
        #expect(result.allSatisfy { $0.tableCopySource == nil })
    }

    @Test func theFooterSitsOnTheLastMarkdownPieceAfterACall() {
        let result = pieces([message("m", .assistant, [
            .markdown("One."),
            toolCall("t1"),
            .markdown("Two.")
        ])])
        #expect(result.map(\.id) == ["m/0/0", "m/1", "m/2/0"])
        #expect(result[2].messageCopySource == "One.\n\nTwo.")
        #expect(result.dropLast().allSatisfy { $0.messageCopySource == nil })
        #expect(result[2].offersMessageCopy == true)
    }

    @Test func theFooterStaysOnTheMarkdownWhenACallFollowsIt() {
        let result = pieces([message("m", .assistant, [
            .markdown("One.\n\nTwo."),
            toolCall("t1")
        ])])
        #expect(result.map(\.id) == ["m/0/0", "m/0/1", "m/1"])
        #expect(result[1].messageCopySource == "One.\n\nTwo.")
        #expect(result[1].offersMessageCopy == true)
        #expect(result[0].messageCopySource == nil)
        #expect(result[2].messageCopySource == nil)
        #expect(result[2].timestamp == nil)
    }

    /// Each new block would move the footer to another piece mid-turn, so it
    /// waits for the turn to end.
    @Test func anInFlightReplyHasNoFooter() {
        let blocks: [ChatBlock] = [.markdown("One."), toolCall("t1")]
        let working = pieces([message("m", .assistant, blocks)], status: .working)
        #expect(working.allSatisfy { $0.messageCopySource == nil })

        let parked = pieces([message("m", .assistant, blocks)], status: .permissionNeeded)
        #expect(parked.allSatisfy { $0.messageCopySource == nil })
    }

    /// Only the reply is in flight; the prompt the user sent is finished.
    @Test func aSentPromptKeepsItsFooterWhileTheReplyWorks() {
        let result = pieces([message("m", .user, [.markdown("go")])], status: .working)
        #expect(result.first { $0.messageID == "m" }?.messageCopySource == "go")
    }

    /// The footer shows it beside the copy button, and only there.
    @Test func theLastPieceCarriesTheMessagesTimestamp() {
        let sent = Date(timeIntervalSince1970: 1_700_000_000)
        let result = pieces([ChatMessage(
            id: "m",
            role: .assistant,
            blocks: [.markdown("One."), .markdown("Two.")],
            timestamp: sent
        )])
        #expect(result.last?.timestamp == sent)
        #expect(result.dropLast().allSatisfy { $0.timestamp == nil })
    }

    /// A transcript line without a time still offers the copy button.
    @Test func aMessageWithoutATimestampStillOffersCopy() {
        let result = pieces([message("m", .assistant, [.markdown("One.")])])
        #expect(result.last?.timestamp == nil)
        #expect(result.last?.offersMessageCopy == true)
    }

    /// What the user said is as worth copying as what Claude answered.
    @Test func aUserMessageGetsTheFooterToo() {
        let result = pieces([message("m", .user, [.markdown("Fix the build")])])
        #expect(result.last?.messageCopySource == "Fix the build")
        #expect(result.last?.offersMessageCopy == true)
    }

    /// A message that says nothing in markdown has nothing to copy.
    @Test func aMessageWithoutMarkdownOffersNoMessageCopy() {
        let result = pieces([message("m", .assistant, [toolCall("t1")])])
        #expect(result.allSatisfy { $0.messageCopySource == nil })
    }

    /// The source is still growing, so the button would copy a fragment.
    @Test func aLiveMessageOffersNoMessageCopy() {
        let result = pieces(
            [message("m", .assistant, [.markdown("Partial")])],
            streaming: ChatStreamHandoff.Overlay(text: "and more")
        )
        #expect(result.allSatisfy { !$0.offersMessageCopy })
    }
}
