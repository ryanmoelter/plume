import Foundation

/// Turns the transcript's messages into the list's lazy items.
///
/// `LazyVStack` estimates the items it has not realized from the ones it has,
/// and a realized set whose heights differ by a large factor never settles
/// under momentum scrolling — the hang in `docs/chat-list-hang.md`. One item
/// per message put a 2,000 pt reply beside a 23 pt notice, so the list places
/// pieces instead: one markdown block, one tool call, one notice, each capped
/// at `ChatPieceMetrics.maxPieceHeight` — by splitting a long list, and by
/// bounding a long code block so it scrolls inside itself. Nothing the reader
/// sees changes.
///
/// Pure, so the whole model can be tested without a view.
enum ChatPieceSplitter {
    static func pieces(
        for messages: [ChatMessage],
        status: TaskStatus,
        hiddenToolUseIDs: Set<String>,
        streaming: ChatStreamHandoff.Overlay,
        dimensions: Dimensions,
        parse: (String) -> [MarkdownBlock] = MarkdownBlock.parse
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
            let context = MessageContext(
                message: message,
                needsInput: isLast && status == .needsInput,
                isWorking: isLast && status == .working,
                hiddenToolUseIDs: isLast ? hiddenToolUseIDs : [],
                streaming: isLast && attachesToLastMessage ? streaming : .init(),
                previousMessageKind: previousMessageKind,
                dimensions: dimensions
            )
            let group = pieces(of: context, parse: parse)
            guard !group.isEmpty else { continue }
            result += grouped(group, role: message.role)
            previousMessageKind = ChatBlockSpacing.rowKind(of: message)
        }

        if !attachesToLastMessage, !streaming.isEmpty {
            // The stream stands in for the assistant message it will become,
            // so it takes that message's gap and the reply doesn't shift as
            // the transcript takes over.
            let leading = ChatBlockSpacing.rowTopInset(
                previous: previousMessageKind,
                current: .other,
                dimensions: dimensions
            )
            result += grouped(
                streamingPieces(streaming, wash: .none, leading: leading, dimensions: dimensions),
                role: .assistant
            )
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

        /// The gap above the message's first piece.
        var leadingInset: CGFloat {
            ChatBlockSpacing.rowTopInset(
                previous: previousMessageKind,
                current: ChatBlockSpacing.rowKind(of: message),
                dimensions: dimensions
            )
        }
    }

    private static func pieces(
        of context: MessageContext,
        parse: (String) -> [MarkdownBlock]
    ) -> [ChatPiece] {
        let message = context.message
        var result: [ChatPiece] = []
        var previousBlockKind: ChatBlockSpacing.Kind?

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
            result += pieces(
                of: block,
                at: blockIndex,
                in: context,
                leading: leading,
                parse: parse
            )
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
                id: "\(message.id)/working",
                messageID: message.id,
                role: message.role,
                content: .working,
                wash: context.wash,
                topInset: result.isEmpty ? context.leadingInset : context.dimensions.messageBlockSpacing
            ))
        }

        return result
    }

    private static func pieces(
        of block: ChatBlock,
        at blockIndex: Int,
        in context: MessageContext,
        leading: CGFloat,
        parse: (String) -> [MarkdownBlock]
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
        _ blocks: [MarkdownBlock],
        idPrefix: String,
        messageID: String,
        role: ChatMessage.Role,
        wash: ChatPiece.Wash,
        leading: CGFloat,
        dimensions: Dimensions,
        streamSources: [String] = []
    ) -> [ChatPiece] {
        var result: [ChatPiece] = []
        for (index, block) in blocks.enumerated() {
            let blockLeading = index == 0
                ? leading
                : ChatBlockSpacing.markdownBlockTopInset(block, at: index, dimensions: dimensions)
            let segments = segments(of: block, at: index)
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
                    streamSource: segments.count == 1 && index < streamSources.count
                        ? streamSources[index]
                        : nil
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

    private static func segments(of block: MarkdownBlock, at index: Int) -> [Segmented] {
        switch block {
        // A code block is never split. It stays one piece and `CodeSegmentView`
        // bounds a long one at `ChatPieceMetrics.maxCodeHeight`, scrolling
        // inside itself, so the reader keeps one continuous block to scroll.
        case .codeBlock(let language, let code):
            return [Segmented(
                content: .codeSegment(CodeSegment(
                    language: language,
                    code: code,
                    isMermaid: MermaidDocument.isMermaidFence(language: language)
                )),
                joinInset: 0
            )]

        case .bulletList(let items), .numberedList(let items):
            let kind: ListSegment.Kind = {
                if case .numberedList = block { return .numbered }
                return .bullet
            }()
            guard ChatPieceMetrics.splitsList(items) else {
                return [Segmented(
                    content: .listSegment(ListSegment(kind: kind, items: items)),
                    joinInset: 0
                )]
            }
            let chunks = ChatPieceMetrics.listChunks(items)
            var start = 1
            return chunks.enumerated().map { position, chunk in
                defer { start += chunk.count }
                return Segmented(
                    content: .listSegment(ListSegment(
                        kind: kind,
                        items: chunk,
                        startNumber: start,
                        position: place(position, of: chunks.count)
                    )),
                    joinInset: ChatBlockSpacing.listSegmentSpacing
                )
            }

        default:
            // A table's columns would size independently either side of a
            // join; prose and headings are never long enough to be worth it.
            return [Segmented(content: .markdown(block, index: index), joinInset: 0)]
        }
    }

    /// The turn in flight: the thinking text, then the prose it has produced,
    /// with only the block still growing left live.
    ///
    /// Everything but the tail block is settled markdown, so a long reply
    /// mid-stream is as bounded as the transcript it becomes. Parsing is not
    /// prefix-stable — a delimiter line re-reads the paragraph above it as a
    /// table — so a settled piece can be reinterpreted while the stream runs.
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
        let settled = ChatStreamHandoff.settledBlocks(in: overlay.text)

        result += markdownPieces(
            settled.blocks,
            idPrefix: "stream",
            messageID: "stream",
            role: .assistant,
            wash: wash,
            leading: textLeading,
            dimensions: dimensions,
            streamSources: settled.sources
        )

        guard !settled.tail.isEmpty, let tailBlock = settled.tailBlock else { return result }
        let tailLeading: CGFloat = settled.blocks.isEmpty
            ? textLeading
            : ChatBlockSpacing.markdownBlockTopInset(
                tailBlock,
                at: settled.blocks.count,
                dimensions: dimensions
            )
        // Keyed by its block index, not by being the live one, so the piece
        // keeps its identity — and so the reveal keeps its progress — when
        // the block completes and joins the settled ones above.
        //
        // Never split, however long it grows. A reveal counts characters of
        // one source, and the block is about to settle anyway.
        result.append(ChatPiece(
            id: "stream/\(settled.blocks.count)",
            messageID: "stream",
            role: .assistant,
            content: .markdown(tailBlock, index: settled.blocks.count),
            wash: wash,
            topInset: tailLeading,
            streamSource: settled.tail,
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
