import Foundation

/// Turns the transcript's messages into the list's items.
///
/// One item per message would put a 2,000 pt reply beside a 23 pt notice, so
/// the list places pieces instead: one markdown block, one tool call, one
/// notice. Nothing the reader sees changes — `docs/chat-list-hang.md` records
/// why the split exists.
///
/// Pure, so the whole model can be tested without a view.
enum ChatPieceSplitter {
    static func pieces(
        for messages: [ChatMessage],
        status: TaskStatus,
        hiddenToolUseIDs: Set<String>,
        streaming: ChatStreamHandoff.Overlay,
        dimensions: Dimensions,
        parse: (String) -> [MarkdownBlock.Parsed] = MarkdownBlock.parseWithSources
    ) -> [ChatPiece] {
        var result: [ChatPiece] = []
        let lastMessageID = messages.last?.id
        let attachesToLastMessage = messages.last?.role == .assistant
        // Nil until something has actually been drawn, so a message the dock
        // has emptied neither takes space nor spaces what follows it.
        var previousMessageKind: ChatBlockSpacing.Kind?

        for message in messages {
            let isLast = ChatScrollAnchor.isEligibleForLiveStatus(
                messageID: message.id,
                lastMessageID: lastMessageID
            )
            let messageHiddenToolUseIDs = isLast ? hiddenToolUseIDs : []
            let context = MessageContext(
                message: message,
                needsInput: isLast && status.wantsAttention,
                isWorking: isLast && status == .working,
                hiddenToolUseIDs: messageHiddenToolUseIDs,
                streaming: isLast && attachesToLastMessage ? streaming : .init(),
                previousMessageKind: previousMessageKind,
                dimensions: dimensions
            )
            let group = pieces(of: context, parse: parse)
            guard !group.isEmpty else { continue }
            result += grouped(group, role: message.role)
            // The last *rendered* block, not the whole message: a message
            // ending in a call after prose still opens a run with whatever
            // follows it, and a message whose only call the dock has taken
            // over draws nothing here and must not count as either.
            previousMessageKind = ChatBlockSpacing.lastRenderedKind(
                message.blocks,
                hiddenToolUseIDs: messageHiddenToolUseIDs
            ) ?? previousMessageKind
        }

        if !attachesToLastMessage, !streaming.isEmpty || status == .working {
            // The turn stands in for the assistant message it will become,
            // so it takes that message's gap and the reply doesn't shift as
            // the transcript takes over. The working indicator belongs to it
            // rather than to the user's bubble above.
            let leading = ChatBlockSpacing.rowTopInset(
                previous: previousMessageKind,
                current: .other,
                dimensions: dimensions
            )
            var turn = streamingPieces(streaming, wash: .none, leading: leading, dimensions: dimensions)
            if status == .working {
                turn.append(ChatPiece(
                    id: Self.workingID,
                    messageID: "stream",
                    role: .assistant,
                    content: .working,
                    wash: .none,
                    topInset: turn.isEmpty ? leading : dimensions.workingIndicatorSpacing
                ))
            }
            result += grouped(turn, role: .assistant)
        }

        return result
    }

    /// Everything one message's pieces need that isn't the message.
    private struct MessageContext {
        let message: ChatMessage
        let needsInput: Bool
        let isWorking: Bool
        let hiddenToolUseIDs: Set<String>
        let streaming: ChatStreamHandoff.Overlay
        let previousMessageKind: ChatBlockSpacing.Kind?
        let dimensions: Dimensions

        var wash: ChatPiece.Wash {
            switch message.role {
            case .user: isInjectedOnly ? .none : .bubble
            case .assistant: needsInput ? .attention : .none
            case .notice: .none
            }
        }

        /// An injected line is not the user speaking, so it skips the bubble
        /// and sits full-width like the transcript's own asides.
        var isInjectedOnly: Bool {
            !message.blocks.isEmpty && message.blocks.allSatisfy { block in
                if case .injected = block { return true }
                return false
            }
        }

        /// Every markdown block of the message, as one document. Nil when the
        /// message says nothing in markdown — a lone tool call has no prose
        /// to copy.
        var messageMarkdown: String? {
            let blocks = message.blocks.compactMap { block -> String? in
                guard case .markdown(let text) = block else { return nil }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            return blocks.isEmpty ? nil : blocks.joined(separator: "\n\n")
        }

        /// An assistant message the turn can still add blocks to. A parked
        /// turn counts: answering the prompt resumes it.
        var isInFlight: Bool {
            message.role == .assistant && (isWorking || needsInput || !streaming.isEmpty)
        }

        /// The gap above the message's first piece, from what the previous
        /// message actually ended on and what this one actually opens with —
        /// not from whether either message is calls throughout.
        var leadingInset: CGFloat {
            let current = ChatBlockSpacing.firstRenderedKind(
                message.blocks,
                hiddenToolUseIDs: hiddenToolUseIDs
            ) ?? .other
            return ChatBlockSpacing.rowTopInset(
                previous: previousMessageKind,
                current: current,
                dimensions: dimensions
            )
        }
    }

    private static func pieces(
        of context: MessageContext,
        parse: (String) -> [MarkdownBlock.Parsed]
    ) -> [ChatPiece] {
        let message = context.message
        var result: [ChatPiece] = []
        var previousBlockKind: ChatBlockSpacing.Kind?
        var lastMarkdownPieceIndex: Int?

        for (blockIndex, block) in message.blocks.enumerated() {
            // A block that draws nothing takes no item and does not space
            // what follows it — an empty lazy item is exactly the kind of
            // near-zero height the ceiling exists to keep away from.
            guard ChatBlockSpacing.isRendered(block, hiddenToolUseIDs: context.hiddenToolUseIDs)
            else { continue }
            let leading = result.isEmpty
                ? context.leadingInset
                : ChatBlockSpacing.blockTopInset(
                    previous: previousBlockKind,
                    current: ChatBlockSpacing.kind(of: block),
                    role: message.role,
                    dimensions: context.dimensions
                )
            let blockPieces = pieces(
                of: block,
                at: blockIndex,
                in: context,
                leading: leading,
                parse: parse
            )
            result += blockPieces
            if case .markdown = block, !blockPieces.isEmpty {
                lastMarkdownPieceIndex = result.count - 1
            }
            previousBlockKind = ChatBlockSpacing.kind(of: block)
        }

        if !context.streaming.isEmpty {
            let leading = result.isEmpty
                ? context.leadingInset
                : ChatBlockSpacing.streamingTopInset(
                    previous: previousBlockKind,
                    dimensions: context.dimensions
                )
            result += streamingPieces(
                context.streaming,
                wash: context.wash,
                leading: leading,
                dimensions: context.dimensions
            )
        }

        if context.isWorking, message.role == .assistant {
            result.append(ChatPiece(
                id: Self.workingID,
                messageID: message.id,
                role: message.role,
                content: .working,
                wash: context.wash,
                topInset: result.isEmpty ? context.leadingInset : context.dimensions.workingIndicatorSpacing
            ))
        }

        // One footer for the whole reply, under the prose it copies rather than
        // under a tool call that followed it. Withheld while the turn is in
        // flight: each new markdown block would move it to another piece, and
        // both pieces would change height.
        if !context.isInFlight, let index = lastMarkdownPieceIndex, let whole = context.messageMarkdown {
            result[index].messageCopySource = whole
            result[index].timestamp = message.timestamp
        }

        return result
    }

    private static func pieces(
        of block: ChatBlock,
        at blockIndex: Int,
        in context: MessageContext,
        leading: CGFloat,
        parse: (String) -> [MarkdownBlock.Parsed]
    ) -> [ChatPiece] {
        let message = context.message
        let base = "\(message.id)/\(blockIndex)"

        func single(_ content: ChatPiece.Content) -> [ChatPiece] {
            [ChatPiece(
                id: base,
                messageID: message.id,
                role: message.role,
                content: content,
                wash: context.wash,
                topInset: leading
            )]
        }

        switch block {
        case .markdown(let text):
            return markdownPieces(
                parse(text),
                idPrefix: base,
                messageID: message.id,
                role: message.role,
                wash: context.wash,
                leading: leading,
                dimensions: context.dimensions
            )
        case .thinking(let text):
            return single(.thinking(text))
        case .toolCall(let call):
            // The positional guess, for the TUI transport. Headless, a
            // stalled call is named exactly and the dock draws it instead.
            let isPending = context.needsInput && blockIndex == message.blocks.count - 1
            return single(.toolCall(call, isPending: isPending))
        case .injected(let kind, let text):
            return single(.injected(kind, text: text))
        case .notice(let notice):
            return single(.notice(notice))
        case .image(let image):
            return single(.image(image))
        }
    }

    /// One `.markdown` block's parsed blocks, each its own piece, oversized
    /// ones split further.
    private static func markdownPieces(
        _ parsed: [MarkdownBlock.Parsed],
        idPrefix: String,
        messageID: String,
        role: ChatMessage.Role,
        wash: ChatPiece.Wash,
        leading: CGFloat,
        dimensions: Dimensions,
        streams: Bool = false
    ) -> [ChatPiece] {
        var result: [ChatPiece] = []
        for (index, entry) in parsed.enumerated() {
            let block = entry.block
            let blockLeading = index == 0
                ? leading
                : ChatBlockSpacing.markdownBlockTopInset(block, at: index, dimensions: dimensions)
            let segments = segments(of: block, at: index, dimensions: dimensions)
            for (segmentIndex, segment) in segments.enumerated() {
                result.append(ChatPiece(
                    id: segments.count == 1
                        ? "\(idPrefix)/\(index)"
                        : "\(idPrefix)/\(index)/\(segmentIndex)",
                    messageID: messageID,
                    role: role,
                    content: segment.content,
                    wash: wash,
                    topInset: segmentIndex == 0 ? blockLeading : segment.joinInset,
                    // Only a block that stayed whole can go on typing: a
                    // reveal counts characters of one source, and a split
                    // block has no single piece to count them in.
                    streamSource: streams && segments.count == 1 ? entry.source : nil,
                    // A whole block copies the lines it was parsed from; a
                    // segment has no lines of its own, so it is written back.
                    copySource: segments.count == 1
                        ? entry.source
                        : MarkdownSource.markdown(of: segment.content)
                ))
            }
        }
        return result
    }

    private struct Segmented {
        let content: ChatPiece.Content
        /// The gap above this segment when it follows another segment of the
        /// same block.
        let joinInset: CGFloat
    }

    private static func segments(
        of block: MarkdownBlock,
        at index: Int,
        dimensions: Dimensions
    ) -> [Segmented] {
        switch block {
        // A code block is never split, so the reader keeps one continuous
        // block to scroll.
        case .codeBlock(let language, let code):
            return [Segmented(
                content: .codeSegment(CodeSegment(
                    language: language,
                    code: code,
                    isMermaid: MermaidDocument.isMermaidFence(language: language)
                )),
                joinInset: 0
            )]

        case .list(let items):
            // One piece per item, however short. A list item is already a
            // unit with a gap above it, so the seam is free, and one item per
            // piece is the most even height spread the list can offer. Each
            // item carries its own depth and number, so a piece of one needs
            // nothing from the items it was cut away from.
            guard items.count > 1 else {
                return [Segmented(content: .listSegment(ListSegment(items: items)), joinInset: 0)]
            }
            return items.enumerated().map { position, item in
                Segmented(
                    content: .listSegment(ListSegment(
                        items: [item],
                        position: place(position, of: items.count)
                    )),
                    joinInset: ChatBlockSpacing.listSegmentSpacing
                )
            }

        // Prose takes one piece per paragraph, however short: the seam is a
        // gap the source already has, so it costs the reader nothing, and an
        // even spread of heights is the whole point — the estimator's error
        // comes from the variance within the realized set, not from how many
        // items there are.
        case .quote(let text, _):
            let parts = ChatPieceMetrics.proseParagraphs(text)
            guard parts.count > 1 else { break }
            return parts.enumerated().map { position, part in
                // The gap is drawn inside the bar, so a split quote reads as
                // one. The list must not also pay it above the piece.
                Segmented(
                    content: .markdown(.quote(part, continues: position > 0), index: index),
                    joinInset: 0
                )
            }

        case .paragraph(let text):
            let parts = ChatPieceMetrics.proseParagraphs(text)
            guard parts.count > 1 else { break }
            return parts.map { part in
                Segmented(
                    content: .markdown(.paragraph(part), index: index),
                    joinInset: dimensions.blockSpacing
                )
            }

        default:
            break
        }
        // A table's columns would size independently either side of a join,
        // and a heading is never long enough to be worth one.
        return [Segmented(content: .markdown(block, index: index), joinInset: 0)]
    }

    /// The turn in flight: the thinking text, then the prose it has produced,
    /// with only the block still growing left live.
    ///
    /// Everything but the tail block is settled markdown, so a long reply
    /// mid-stream is as bounded as the transcript it becomes. Parsing is not
    /// prefix-stable — a delimiter line re-reads the paragraph above it as a
    /// table — so a settled piece can be reinterpreted while the stream runs.
    /// One id for the working indicator wherever it sits, so the row that
    /// draws it survives the stream becoming a transcript message and its
    /// ellipsis keeps pulsing through the handoff instead of restarting.
    static let workingID = "working"

    private static func streamingPieces(
        _ overlay: ChatStreamHandoff.Overlay,
        wash: ChatPiece.Wash,
        leading: CGFloat,
        dimensions: Dimensions
    ) -> [ChatPiece] {
        var result: [ChatPiece] = []

        if !overlay.thinking.isEmpty {
            result.append(ChatPiece(
                id: "stream/thinking",
                messageID: "stream",
                role: .assistant,
                content: .streaming(ChatStreamHandoff.Overlay(thinking: overlay.thinking)),
                wash: wash,
                topInset: leading
            ))
        }

        guard !overlay.text.isEmpty else { return result }
        let textLeading = result.isEmpty ? leading : ChatBlockSpacing.streamingBlockSpacing
        let stream = ChatStreamHandoff.settledBlocks(in: overlay.text)

        result += markdownPieces(
            stream.settled,
            idPrefix: "stream",
            messageID: "stream",
            role: .assistant,
            wash: wash,
            leading: textLeading,
            dimensions: dimensions,
            streams: true
        )

        guard !stream.tail.isEmpty, let tailBlock = stream.tailBlock else { return result }
        let tailLeading: CGFloat = stream.blocks.isEmpty
            ? textLeading
            : ChatBlockSpacing.markdownBlockTopInset(
                tailBlock,
                at: stream.blocks.count,
                dimensions: dimensions
            )
        // Keyed by its block index, not by being the live one, so the piece
        // keeps its identity — and so the reveal keeps its progress — when
        // the block completes and joins the settled ones above.
        //
        // Never split, however long it grows. A reveal counts characters of
        // one source, and the block is about to settle anyway.
        result.append(ChatPiece(
            id: "stream/\(stream.blocks.count)",
            messageID: "stream",
            role: .assistant,
            content: .markdown(tailBlock, index: stream.blocks.count),
            wash: wash,
            topInset: tailLeading,
            streamSource: stream.tail,
            isArriving: true
        ))
        return result
    }

    /// Assigns each piece its place in the message's wash group, and the
    /// padding a notice message pays around its own.
    private static func grouped(_ pieces: [ChatPiece], role: ChatMessage.Role) -> [ChatPiece] {
        guard pieces.count > 1 else {
            return pieces.map { piece in
                var piece = piece
                if role == .notice {
                    piece.topInset += ChatBlockSpacing.noticeVerticalPadding
                    piece.bottomInset = ChatBlockSpacing.noticeVerticalPadding
                }
                return piece
            }
        }
        return pieces.enumerated().map { index, piece in
            var piece = piece
            piece.segment = place(index, of: pieces.count)
            if role == .notice {
                if piece.segment.isFirst { piece.topInset += ChatBlockSpacing.noticeVerticalPadding }
                if piece.segment.isLast { piece.bottomInset = ChatBlockSpacing.noticeVerticalPadding }
            }
            return piece
        }
    }

    private static func place(_ index: Int, of count: Int) -> ChatPiece.Segment {
        if count <= 1 { return .single }
        if index == 0 { return .first }
        return index == count - 1 ? .last : .middle
    }
}
