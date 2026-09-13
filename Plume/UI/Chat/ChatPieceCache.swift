import Foundation

/// Memoizes markdown parsing across rebuilds of one chat list's pieces.
///
/// `TranscriptStore` replaces the whole message array on every file change,
/// so a rebuild that parsed every message would cost the transcript's whole
/// length each time. Keyed by the markdown source, which is what parsing
/// depends on, and pruned to what the current messages hold — so the cache is
/// exactly as large as the transcript on screen and never outlives the tab.
///
/// Separate from `MarkdownCache`, whose 512 entries are a render cache for
/// realized rows: filling it from here would evict what the view needs.
@MainActor
final class ChatPieceCache {
    private var parsed: [String: [MarkdownBlock.Parsed]] = [:]

    /// How many sources have actually been parsed since this cache was made.
    private(set) var parseCount = 0

    func pieces(
        for messages: [ChatMessage],
        status: TaskStatus,
        hiddenToolUseIDs: Set<String>,
        streaming: ChatStreamHandoff.Overlay,
        dimensions: Dimensions
    ) -> [ChatPiece] {
        var next: [String: [MarkdownBlock.Parsed]] = [:]
        next.reserveCapacity(parsed.count)
        let pieces = ChatPieceSplitter.pieces(
            for: messages,
            status: status,
            hiddenToolUseIDs: hiddenToolUseIDs,
            streaming: streaming,
            dimensions: dimensions,
            parse: { markdown in
                if let reused = next[markdown] { return reused }
                let blocks = parsed[markdown] ?? {
                    parseCount += 1
                    return MarkdownBlock.parseWithSources(markdown)
                }()
                next[markdown] = blocks
                return blocks
            }
        )
        parsed = next
        return pieces
    }
}
