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

    /// A message the reader sees as tool calls and nothing else, so a run
    /// continues through it.
    static func rowKind(of message: ChatMessage) -> Kind {
        guard !message.blocks.isEmpty else { return .other }
        return message.blocks.allSatisfy { kind(of: $0) == .toolCall } ? .toolCall : .other
    }

    /// Gap above each message in the list, in order.
    static func rowTopInsets(_ messages: [ChatMessage], dimensions: Dimensions) -> [CGFloat] {
        var previous: Kind?
        return messages.map { message in
            let current = rowKind(of: message)
            defer { previous = current }
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

    /// Gap above the turn in flight, drawn below `previous`.
    ///
    /// Nil `previous` is the standalone mount, where the row it sits in
    /// already pays the gap. After a tool call the streamed text retires into
    /// a message of its own — the tool's result ends the assistant's run — so
    /// it takes the gap between two messages; after prose it stays in the
    /// message it is already drawn in and takes the gap between two blocks.
    static func streamingTopInset(previous: Kind?, dimensions: Dimensions) -> CGFloat {
        switch previous {
        case .none: 0
        case .toolCall: dimensions.messageSpacing
        case .other: dimensions.messageBlockSpacing
        }
    }

    private static func collapses(_ previous: Kind, _ current: Kind) -> Bool {
        previous == .toolCall && current == .toolCall
    }

    private static func isRendered(_ block: ChatBlock, hiddenToolUseIDs: Set<String>) -> Bool {
        if case .toolCall(let call) = block { return !hiddenToolUseIDs.contains(call.id) }
        return true
    }
}
