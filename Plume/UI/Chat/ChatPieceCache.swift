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
    /// Each source's link targets, in order, nil where a link isn't one.
    private var linkTargets: [String: [ReferenceTarget?]] = [:]
    /// The parse with each chip's title written in, keyed by the titles it
    /// was written with.
    private var rewritten: [RewriteKey: [MarkdownBlock.Parsed]] = [:]

    private struct Inputs: Equatable {
        let messages: [ChatMessage]
        let status: TaskStatus
        let hiddenToolUseIDs: Set<String>
        let expandedAgentMessages: Set<String>
        let dimensions: Dimensions
        let referenceRevision: Int
        let linkBase: URL?
    }

    private struct RewriteKey: Hashable {
        let source: String
        let titles: [String?]
    }

    /// Every chip-shaped target the last build's links named.
    private(set) var referenceTargets: Set<ReferenceTarget> = []

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
        dimensions: Dimensions,
        referenceRevision: Int = 0,
        linkBase: URL? = nil,
        referenceTitle: (ReferenceTarget) -> String? = { _ in nil }
    ) -> [ChatPiece] {
        let inputs = Inputs(
            messages: messages,
            status: status,
            hiddenToolUseIDs: hiddenToolUseIDs,
            expandedAgentMessages: expandedAgentMessages,
            dimensions: dimensions,
            referenceRevision: referenceRevision,
            linkBase: linkBase
        )
        if let lastBuild, lastBuild.inputs == inputs { return lastBuild.pieces }
        if lastBuild?.inputs.linkBase != linkBase { linkTargets = [:] }

        var next: [String: [MarkdownBlock.Parsed]] = [:]
        next.reserveCapacity(parsed.count)
        var nextTargets: [String: [ReferenceTarget?]] = [:]
        var nextRewritten: [RewriteKey: [MarkdownBlock.Parsed]] = [:]
        var foundTargets = Set<ReferenceTarget>()
        let pieces = ChatPieceSplitter.pieces(
            for: messages,
            status: status,
            hiddenToolUseIDs: hiddenToolUseIDs,
            expandedAgentMessages: expandedAgentMessages,
            dimensions: dimensions,
            parse: { markdown in
                let blocks = next[markdown] ?? parsed[markdown] ?? {
                    parseCount += 1
                    return MarkdownBlock.parseWithSources(markdown)
                }()
                next[markdown] = blocks
                guard markdown.contains("](") else { return blocks }

                let targets = nextTargets[markdown] ?? linkTargets[markdown] ?? Self.targets(in: markdown, base: linkBase)
                nextTargets[markdown] = targets
                foundTargets.formUnion(targets.compactMap { $0 })
                let titles = targets.map { $0.flatMap(referenceTitle) }
                guard titles.contains(where: { $0 != nil }) else { return blocks }

                let key = RewriteKey(source: markdown, titles: titles)
                if let reused = nextRewritten[key] ?? rewritten[key] {
                    nextRewritten[key] = reused
                    return reused
                }
                let chipped = blocks.map { entry in
                    MarkdownBlock.Parsed(
                        block: entry.block.mappingInline { text in
                            ReferenceChipText.rewrite(text) { destination in
                                ReferenceChipText.url(forDestination: destination)
                                    .flatMap { ReferenceTarget.classify($0, base: linkBase) }
                                    .flatMap(referenceTitle)
                            }
                        },
                        source: entry.source
                    )
                }
                nextRewritten[key] = chipped
                return chipped
            }
        )
        parsed = next
        linkTargets = nextTargets
        rewritten = nextRewritten
        referenceTargets = foundTargets
        lastBuild = (inputs, pieces)
        return pieces
    }

    private static func targets(in markdown: String, base: URL?) -> [ReferenceTarget?] {
        let ns = markdown as NSString
        return MarkdownHighlighter.linkRanges(in: markdown).filter { !$0.isImage }.map { link in
            ReferenceChipText.url(forDestination: ns.substring(with: link.destination))
                .flatMap { ReferenceTarget.classify($0, base: base) }
        }
    }
}
