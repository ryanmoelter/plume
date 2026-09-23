import Foundation

/// Chooses the gap above a chat item from what sits above it.
///
/// A run of tool calls should read as one list rather than as several
/// separated statements, so consecutive calls sit tight and everything else
/// keeps the full gap. The same rule applies between two message rows as
/// within one message: a tool result ends the assistant's run in the
/// transcript, so a run of calls arrives as a run of one-block messages.
enum ChatBlockSpacing {
    /// What an item is, as far as spacing is concerned.
    enum Kind: Equatable {
        case toolCall
        case other
    }

    static func kind(of block: ChatBlock) -> Kind {
        if case .toolCall = block { return .toolCall }
        return .other
    }

    /// Gap above each message in the list, in order.
    ///
    /// A run of calls continues across a message boundary wherever the last
    /// rendered block above it and the first rendered block below it are both
    /// calls — not only when a whole message is calls and nothing else, so a
    /// message that ends in a call after prose still tightens against a call
    /// that opens the next one.
    static func rowTopInsets(
        _ messages: [ChatMessage],
        hiddenToolUseIDs: Set<String> = [],
        dimensions: Dimensions
    ) -> [CGFloat] {
        var previous: Kind?
        return messages.map { message in
            guard let current = firstRenderedKind(message.blocks, hiddenToolUseIDs: hiddenToolUseIDs) else {
                return 0
            }
            defer { previous = lastRenderedKind(message.blocks, hiddenToolUseIDs: hiddenToolUseIDs) }
            return rowTopInset(previous: previous, current: current, dimensions: dimensions)
        }
    }

    /// Gap above one message row. `previous` is nil for the list's first row.
    static func rowTopInset(previous: Kind?, current: Kind, dimensions: Dimensions) -> CGFloat {
        guard let previous else { return dimensions.verticalPadding }
        return collapses(previous, current) ? dimensions.toolCallSpacing : dimensions.messageSpacing
    }

    /// Gap above each block of a message, in order.
    ///
    /// A block the pending dock draws instead renders nothing here, so it
    /// takes no inset and does not count as the block above the next one.
    static func blockTopInsets(
        _ blocks: [ChatBlock],
        hiddenToolUseIDs: Set<String> = [],
        dimensions: Dimensions
    ) -> [CGFloat] {
        var previous: Kind?
        return blocks.map { block in
            guard isRendered(block, hiddenToolUseIDs: hiddenToolUseIDs) else { return 0 }
            let current = kind(of: block)
            defer { previous = current }
            return blockTopInset(previous: previous, current: current, dimensions: dimensions)
        }
    }

    /// Gap above one block. `previous` is nil for a message's first block.
    static func blockTopInset(previous: Kind?, current: Kind, dimensions: Dimensions) -> CGFloat {
        guard let previous else { return 0 }
        return collapses(previous, current) ? dimensions.toolCallSpacing : dimensions.messageBlockSpacing
    }

    /// The last block a message actually draws, or nil when it draws none.
    static func lastRenderedKind(
        _ blocks: [ChatBlock],
        hiddenToolUseIDs: Set<String> = []
    ) -> Kind? {
        blocks.last { isRendered($0, hiddenToolUseIDs: hiddenToolUseIDs) }.map(kind(of:))
    }

    /// The first block a message actually draws, or nil when it draws none.
    static func firstRenderedKind(
        _ blocks: [ChatBlock],
        hiddenToolUseIDs: Set<String> = []
    ) -> Kind? {
        blocks.first { isRendered($0, hiddenToolUseIDs: hiddenToolUseIDs) }.map(kind(of:))
    }

    /// Gap between two blocks of a user's message, from `userBody`'s stack.
    static let userBlockSpacing: CGFloat = 8

    /// Gap between two blocks of a notice message, from `noticeBody`'s stack.
    static let noticeBlockSpacing: CGFloat = 6

    /// Space a notice message pays above its first block and below its last.
    static let noticeVerticalPadding: CGFloat = 4

    /// Gap between two segments of one split list, matching the gap between
    /// the items within a segment.
    static let listSegmentSpacing: CGFloat = 4

    /// Gap above one block, by the role of the message holding it. Only the
    /// assistant's blocks vary with what sits above them; the other two roles
    /// stack at a fixed spacing.
    static func blockTopInset(
        previous: Kind?,
        current: Kind,
        role: ChatMessage.Role,
        dimensions: Dimensions
    ) -> CGFloat {
        guard previous != nil else { return 0 }
        switch role {
        case .assistant:
            return blockTopInset(previous: previous, current: current, dimensions: dimensions)
        case .user:
            return userBlockSpacing
        case .notice:
            return noticeBlockSpacing
        }
    }

    /// Gap above one block of parsed markdown, within the block list one
    /// `.markdown` block produces. Reproduces what `MarkdownView` puts
    /// between its own blocks, including the extra a non-initial heading
    /// takes.
    static func markdownBlockTopInset(
        _ block: MarkdownBlock,
        at index: Int,
        dimensions: Dimensions
    ) -> CGFloat {
        guard index > 0 else { return 0 }
        guard case .heading(let level, _) = block else { return dimensions.blockSpacing }
        return dimensions.blockSpacing + dimensions.headingTopSpacing(level: level)
    }

    private static func collapses(_ previous: Kind, _ current: Kind) -> Bool {
        previous == .toolCall && current == .toolCall
    }

    /// Whether a block draws anything.
    ///
    /// A call the pending dock has taken over draws nothing here, and real
    /// transcripts carry thinking blocks with no text — `ThinkingRow` renders
    /// nothing for those rather than an empty expander. Neither takes a gap
    /// nor counts as the block above the next one.
    static func isRendered(_ block: ChatBlock, hiddenToolUseIDs: Set<String> = []) -> Bool {
        switch block {
        case .toolCall(let call): !hiddenToolUseIDs.contains(call.id)
        case .thinking(let text): !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        default: true
        }
    }
}
