import Foundation

/// Memoizes a chat list's pieces across rebuilds, message by message.
///
/// `TranscriptStore` replaces the whole message array on every file change,
/// and a streamed reply rebuilds every 100 ms, so a rebuild that re-split
/// every message would cost the transcript's whole length each time. Instead
/// each message keeps its finished pieces, and a rebuild re-splits only the
/// messages whose `ChatPieceSplitter.MessageSplitKey` changed, or whose chip
/// titles did. Typically that is the last one or two. Each message also keeps
/// the parse of every markdown source it drew, so a change that re-splits
/// them all (a new width, say) parses nothing again. Everything is pruned to
/// the messages the current build holds, so the cache is exactly as large as
/// the transcript on screen.
///
/// A tab's cache outlives its view (`forTab`), because switching tasks
/// unmounts the chat and remounting it would otherwise re-split the whole
/// transcript on the main thread.
///
/// Separate from `MarkdownCache`, whose 512 entries are a render cache for
/// realized rows: filling it from here would evict what the view needs.
@MainActor
final class ChatPieceCache {
    private var lastBuild: (inputs: Inputs, pieces: [ChatPiece])?
    private var builtOutline: ChatOutline?
    private var entries: [String: MessageEntry] = [:]
    private var artifactTitles: ArtifactChipTitles?
    /// Each piece's outline weight, with the content it was computed from.
    private var outlineWeights: [String: (content: ChatPiece.Content, weight: CGFloat)] = [:]

    private struct Inputs: Equatable {
        let messages: [ChatMessage]
        let status: TaskStatus
        let hiddenToolUseIDs: Set<String>
        let expandedAgentMessages: Set<String>
        let dimensions: Dimensions
        let referenceRevision: Int
        let linkBase: URL?
    }

    /// One markdown source a message drew, parsed, with its chips written in.
    private struct Source {
        let blocks: [MarkdownBlock.Parsed]
        /// Each link's target, in order, nil where a link isn't one. Nil
        /// until scanned, and never scanned for a source with no link.
        var targets: [ReferenceTarget?]?
        /// The chip title each target resolved to when `chipped` was written.
        var titles: [String?]?
        var chipped: [MarkdownBlock.Parsed]?

        var output: [MarkdownBlock.Parsed] { chipped ?? blocks }
    }

    private struct MessageEntry {
        let key: ChatPieceSplitter.MessageSplitKey
        let split: ChatPieceSplitter.MessageSplit
        let sources: [String: Source]
        let targets: [ReferenceTarget]
    }

    /// Every chip-shaped target the last build's links named.
    private(set) var referenceTargets: Set<ReferenceTarget> = []

    /// How many sources have actually been parsed since this cache was made.
    private(set) var parseCount = 0

    /// How many messages have been split rather than reused since this cache
    /// was made.
    private(set) var splitCount = 0

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

    /// The minimap's outline of the last build's pieces, made once per build.
    var outline: ChatOutline {
        if let builtOutline { return builtOutline }
        let pieces = lastBuild?.pieces ?? []
        var weights: [String: (content: ChatPiece.Content, weight: CGFloat)] = [:]
        weights.reserveCapacity(pieces.count)
        let outline = ChatOutlineBuilder.outline(from: pieces) { piece in
            if let known = outlineWeights[piece.id], known.content == piece.content {
                weights[piece.id] = known
                return known.weight
            }
            let weight = ChatOutlineBuilder.weight(of: piece)
            weights[piece.id] = (piece.content, weight)
            return weight
        }
        outlineWeights = weights
        builtOutline = outline
        return outline
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
        referenceTitle: @escaping (ReferenceTarget) -> String? = { _ in nil }
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
        if let lastBuild, lastBuild.inputs == inputs {
            #if DEBUG
            SwitchLatencyProbe.note("pieceCacheHit")
            #endif
            return lastBuild.pieces
        }
        #if DEBUG
        SwitchLatencyProbe.note("pieceCacheMiss")
        #endif
        let artifactTitles = ArtifactChipTitles(messages: messages)
        let build = Build(
            previous: entries,
            linkBase: linkBase,
            targetsReusable: lastBuild.map { $0.inputs.linkBase == linkBase } ?? true,
            titlesReusable: lastBuild?.inputs.referenceRevision == referenceRevision
                && self.artifactTitles == artifactTitles,
            artifactTitles: artifactTitles,
            referenceTitle: referenceTitle
        )
        let pieces = ChatPieceSplitter.pieces(
            for: messages,
            status: status,
            hiddenToolUseIDs: hiddenToolUseIDs,
            expandedAgentMessages: expandedAgentMessages,
            dimensions: dimensions,
            parse: build.parse,
            memo: build
        )
        entries = build.entries
        self.artifactTitles = artifactTitles
        parseCount += build.parseCount
        splitCount += build.splitCount
        referenceTargets = build.foundTargets
        lastBuild = (inputs, pieces)
        builtOutline = nil
        return pieces
    }

    /// One rebuild's state: the memo the splitter asks, and the parse it
    /// calls while splitting a message the memo declined.
    private final class Build: ChatPieceSplitMemo {
        private let previous: [String: MessageEntry]
        private let linkBase: URL?
        /// False when the link base changed, which reclassifies every link.
        private let targetsReusable: Bool
        /// False when a reference title or an artifact's title may have
        /// changed, so each reused message's titles are looked up again.
        private let titlesReusable: Bool
        private let artifactTitles: ArtifactChipTitles
        private let referenceTitle: (ReferenceTarget) -> String?

        private(set) var entries: [String: MessageEntry] = [:]
        private(set) var foundTargets = Set<ReferenceTarget>()
        private(set) var parseCount = 0
        private(set) var splitCount = 0
        /// Shared by every message split in this build, so two messages
        /// drawing the same text parse it once.
        private var built: [String: Source] = [:]
        private var splitting: [String: Source] = [:]
        private var splittingPrevious: [String: Source] = [:]

        init(
            previous: [String: MessageEntry],
            linkBase: URL?,
            targetsReusable: Bool,
            titlesReusable: Bool,
            artifactTitles: ArtifactChipTitles,
            referenceTitle: @escaping (ReferenceTarget) -> String?
        ) {
            self.previous = previous
            self.linkBase = linkBase
            self.targetsReusable = targetsReusable
            self.titlesReusable = titlesReusable
            self.artifactTitles = artifactTitles
            self.referenceTitle = referenceTitle
            entries.reserveCapacity(previous.count + 1)
        }

        func split(for key: ChatPieceSplitter.MessageSplitKey) -> ChatPieceSplitter.MessageSplit? {
            let id = key.message.id
            let entry = previous[id]
            splitting = [:]
            splittingPrevious = entry?.sources ?? [:]
            guard targetsReusable,
                  let entry,
                  entry.key == key,
                  titlesReusable || entry.sources.values.allSatisfy(titlesUnchanged)
            else { return nil }
            entries[id] = entry
            foundTargets.formUnion(entry.targets)
            return entry.split
        }

        func store(_ split: ChatPieceSplitter.MessageSplit, for key: ChatPieceSplitter.MessageSplitKey) {
            splitCount += 1
            entries[key.message.id] = MessageEntry(
                key: key,
                split: split,
                sources: splitting,
                targets: splitting.values.flatMap { $0.targets?.compactMap { $0 } ?? [] }
            )
        }

        private func titlesUnchanged(_ source: Source) -> Bool {
            guard let targets = source.targets else { return true }
            return source.titles == targets.map { $0.flatMap(chipTitle) }
        }

        private func chipTitle(_ target: ReferenceTarget) -> String? {
            if case .artifact(let id) = target { return artifactTitles.title(forArtifact: id) ?? "" }
            return referenceTitle(target)
        }

        func parse(_ markdown: String) -> [MarkdownBlock.Parsed] {
            if let source = splitting[markdown] { return source.output }
            var source: Source
            if let shared = built[markdown] {
                source = shared
            } else if let kept = splittingPrevious[markdown] {
                source = kept
                if !targetsReusable { source = Source(blocks: kept.blocks) }
            } else {
                parseCount += 1
                source = Source(blocks: MarkdownBlock.parseWithSources(markdown))
            }
            defer {
                splitting[markdown] = source
                built[markdown] = source
            }
            guard markdown.contains("](") || markdown.contains("://") else { return source.output }

            let targets = source.targets ?? ChatPieceCache.targets(in: source.blocks, base: linkBase)
            source.targets = targets
            foundTargets.formUnion(targets.compactMap { $0 })
            let titles = targets.map { $0.flatMap(chipTitle) }
            if source.titles != titles {
                source.titles = titles
                source.chipped = titles.contains(where: { $0 != nil }) ? chipped(source.blocks) : nil
            }
            return source.output
        }

        private func chipped(_ blocks: [MarkdownBlock.Parsed]) -> [MarkdownBlock.Parsed] {
            blocks.map { entry in
                MarkdownBlock.Parsed(
                    block: entry.block.mappingInline { text in
                        ReferenceChipText.rewrite(text) { destination, label in
                            let target = ReferenceChipText.url(forDestination: destination)
                                .flatMap { ReferenceTarget.classify($0, base: linkBase) }
                            if case .artifact(let id) = target {
                                return artifactTitles.title(forArtifact: id, label: label, destination: destination)
                            }
                            return target.flatMap(chipTitle)
                        }
                    },
                    source: entry.source
                )
            }
        }
    }

    /// Scanned per block, so a fence's backtick can't pair with an inline
    /// one after it and hide the links between them as code.
    private static func targets(in blocks: [MarkdownBlock.Parsed], base: URL?) -> [ReferenceTarget?] {
        blocks.flatMap { entry -> [ReferenceTarget?] in
            if case .codeBlock = entry.block { return [] }
            let ns = entry.source as NSString
            let labeled = MarkdownHighlighter.linkRanges(in: entry.source).filter { !$0.isImage }.map { link in
                ReferenceChipText.url(forDestination: ns.substring(with: link.destination))
                    .flatMap { ReferenceTarget.classify($0, base: base) }
            }
            let bare = MarkdownHighlighter.bareLinkRanges(in: entry.source).map { link in
                ReferenceChipText.url(forDestination: ns.substring(with: link.url))
                    .flatMap { ReferenceTarget.classify($0, base: base) }
            }
            return labeled + bare
        }
    }
}
