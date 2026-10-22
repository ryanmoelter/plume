import Foundation

/// Memoizes markdown parsing across rebuilds of one chat list's pieces.
///
/// `TranscriptStore` replaces the whole message array on every file change,
/// so a rebuild that parsed every message would cost the transcript's whole
/// length each time. Keyed by the markdown source, which is what parsing
/// depends on, and pruned to what the current messages hold — so the cache is
/// exactly as large as the transcript on screen.
///
/// A tab's cache outlives its view (`forTab`), because switching tasks
/// unmounts the chat and remounting it would otherwise re-split the whole
/// transcript on the main thread.
///
/// Separate from `MarkdownCache`, whose 512 entries are a render cache for
/// realized rows: filling it from here would evict what the view needs.
@MainActor
final class ChatPieceCache {
    private var parsed: [String: [MarkdownBlock.Parsed]] = [:]
    private var lastBuild: (inputs: Inputs, pieces: [ChatPiece])?

    private struct Inputs: Equatable {
        let messages: [ChatMessage]
        let status: TaskStatus
        let hiddenToolUseIDs: Set<String>
        let expandedAgentMessages: Set<String>
        let dimensions: Dimensions
    }

    /// How many sources have actually been parsed since this cache was made.
    private(set) var parseCount = 0

    private static var byTab: [UUID: ChatPieceCache] = [:]
    /// Most recently used last. Bounds how many transcripts' parses stay in
    /// memory for tabs nobody is looking at.
    private static var recentTabs: [UUID] = []
    private static let retainedTabCount = 8

    static func forTab(_ tabID: UUID) -> ChatPieceCache {
        recentTabs.removeAll { $0 == tabID }
        recentTabs.append(tabID)
        if recentTabs.count > retainedTabCount {
            byTab.removeValue(forKey: recentTabs.removeFirst())
        }
        if let cache = byTab[tabID] { return cache }
        let cache = ChatPieceCache()
        byTab[tabID] = cache
        return cache
    }

    static func forget(tabID: UUID) {
        byTab.removeValue(forKey: tabID)
        recentTabs.removeAll { $0 == tabID }
    }

    func pieces(
        for messages: [ChatMessage],
        status: TaskStatus,
        hiddenToolUseIDs: Set<String>,
        expandedAgentMessages: Set<String> = [],
        dimensions: Dimensions
    ) -> [ChatPiece] {
        let inputs = Inputs(
            messages: messages,
            status: status,
            hiddenToolUseIDs: hiddenToolUseIDs,
            expandedAgentMessages: expandedAgentMessages,
            dimensions: dimensions
        )
        if let lastBuild, lastBuild.inputs == inputs { return lastBuild.pieces }

        var next: [String: [MarkdownBlock.Parsed]] = [:]
        next.reserveCapacity(parsed.count)
        let pieces = ChatPieceSplitter.pieces(
            for: messages,
            status: status,
            hiddenToolUseIDs: hiddenToolUseIDs,
            expandedAgentMessages: expandedAgentMessages,
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
        lastBuild = (inputs, pieces)
        return pieces
    }
}
