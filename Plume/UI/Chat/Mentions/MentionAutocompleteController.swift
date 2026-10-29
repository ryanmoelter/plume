import Foundation
import Observation

/// Where mention candidates come from. Injected so tests can gate each
/// source's answer.
@MainActor
protocol MentionSources: AnyObject, Sendable {
    func files(for query: MentionQuery, in directory: String?) async -> [RankedMention]
    /// Without `includingLookups`, only what needs no new request.
    func pullRequests(for query: MentionQuery, in directory: String?, includingLookups: Bool) async -> [RankedMention]
    /// The cache only, with no request.
    func cachedLinearIssues(matching text: String, limit: Int) async -> [RankedMention]
    /// Fills the cache with what a remote search finds.
    func searchLinear(_ text: String) async
}

@MainActor
final class LiveMentionSources: MentionSources {
    func files(for query: MentionQuery, in directory: String?) async -> [RankedMention] {
        await FileMentionIndex.shared.matches(for: query, in: directory, limit: MentionRanker.matchLimit(for: query))
    }

    func pullRequests(for query: MentionQuery, in directory: String?, includingLookups: Bool) async -> [RankedMention] {
        await PullRequestMentionSource.shared.matches(
            for: query,
            in: directory,
            includingLookups: includingLookups,
            limit: MentionRanker.matchLimit(for: query)
        )
    }

    func cachedLinearIssues(matching text: String, limit: Int) async -> [RankedMention] {
        await LinearStore.shared.mentionCandidates(matching: text, limit: limit)
    }

    func searchLinear(_ text: String) async {
        await LinearStore.shared.searchIssues(text)
    }
}

/// The `@`/`#` mention menu's state, fed from the composer's caret.
///
/// `update` is synchronous and cheap; each source loads in its own child
/// task under a generation number, and only the current generation's results
/// land. A source still loading keeps its previous rows, re-ranked against
/// the new query, so the list narrows as the user types instead of blinking
/// empty.
@Observable
final class MentionAutocompleteController: ComposerAutocompleteHandler {
    struct Debounce {
        var linearSearch: Duration = .milliseconds(300)
        var pullRequestSearch: Duration = .milliseconds(400)
        var pullRequestNumber: Duration = .milliseconds(250)
    }

    typealias Sleep = @MainActor (Duration) async throws -> Void

    private(set) var candidates: [MentionCandidate] = []
    private(set) var selectedIndex = 0
    private(set) var isLoading = false
    private(set) var query: MentionQuery?

    /// The panel is on screen, possibly with nothing but a loading footer.
    var isPresented: Bool { query != nil && (!candidates.isEmpty || isLoading) }

    /// There is a row to pick, so the arrows, Tab and Return belong to the
    /// menu.
    var isShowing: Bool { query != nil && !candidates.isEmpty }

    var claimsEscape: Bool { isPresented }
    var claimsReturn: Bool { isPresented && !isShowing }

    @ObservationIgnored var onAccept: (SlashCommandMatcher.AcceptedCommand) -> Void = { _ in }
    /// Called with the reference an accepted row leaves and what it names,
    /// before `onAccept`.
    @ObservationIgnored var onResolve: (MentionReference.Kind, ResolvedMention) -> Void = { _, _ in }
    /// Called each time a query's every source has answered. For tests.
    @ObservationIgnored var didSettle: (() -> Void)?
    /// Called when a superseded query's results arrive and are dropped. For
    /// tests.
    @ObservationIgnored var didDiscard: (() -> Void)?

    private struct Input: Equatable {
        let text: String
        let caretLocation: Int
        let directory: String?
        let isCommandMode: Bool
    }

    @ObservationIgnored private let sources: any MentionSources
    @ObservationIgnored private let debounce: Debounce
    @ObservationIgnored private let sleep: Sleep
    @ObservationIgnored private let homeDirectory: String

    @ObservationIgnored private var lastInput: Input?
    @ObservationIgnored private var text = ""
    @ObservationIgnored private var directory: String?
    @ObservationIgnored private var results: [MentionCandidate.Source: [RankedMention]] = [:]
    @ObservationIgnored private var pending: Set<MentionCandidate.Source> = []
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var load: Task<Void, Never>?
    @ObservationIgnored private var selectedID: String?
    /// The trigger Esc closed the menu on. It stays closed until the caret
    /// leaves that token.
    @ObservationIgnored private var dismissedTrigger: Int?
    /// A multi-word query that found nothing, which by then is most likely
    /// prose. Anything typed on after it stays closed too.
    @ObservationIgnored private var abandoned: (trigger: Int, text: String)?
    @ObservationIgnored private var wholeMarkup: (text: String, markup: MentionMarkup)?

    init(
        sources: (any MentionSources)? = nil,
        debounce: Debounce = Debounce(),
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) {
        self.sources = sources ?? LiveMentionSources()
        self.debounce = debounce
        self.sleep = sleep
        self.homeDirectory = homeDirectory
    }

    func update(text: String, caretLocation: Int, directory: String?, isCommandMode: Bool) {
        let input = Input(text: text, caretLocation: caretLocation, directory: directory, isCommandMode: isCommandMode)
        guard input != lastInput else { return }
        lastInput = input
        self.text = text

        guard !isCommandMode, let query = query(in: text, caretLocation: caretLocation) else {
            dismissedTrigger = nil
            abandoned = nil
            close()
            return
        }
        if dismissedTrigger != query.triggerLocation { dismissedTrigger = nil }
        if let abandoned, abandoned.trigger != query.triggerLocation || !query.text.hasPrefix(abandoned.text) {
            self.abandoned = nil
        }
        guard dismissedTrigger == nil, abandoned == nil else {
            close()
            return
        }

        if let current = self.query, current.triggerLocation == query.triggerLocation,
           current.text == query.text, current.filter == query.filter, current.isQuoted == query.isQuoted,
           directory == self.directory {
            self.query = query
            return
        }
        start(query, directory: directory)
    }

    private func query(in text: String, caretLocation: Int) -> MentionQuery? {
        guard text.contains(where: { $0 == "@" || $0 == "#" }) else { return nil }
        return MentionQuery.query(text: text, caretLocation: caretLocation, markup: markup(for: text, around: caretLocation))
    }

    /// Only a draft with a fence needs the whole text parsed, and that parse
    /// is kept until the text changes, so moving the caret costs one line.
    private func markup(for text: String, around caretLocation: Int) -> MentionMarkup {
        let ns = text as NSString
        let lineStart = ns.lineRange(for: NSRange(location: min(caretLocation, ns.length), length: 0)).location
        guard MentionMarkup.mayBeFenced(before: lineStart, in: ns) else {
            return MentionMarkup.around(caretLocation, in: text)
        }
        if let wholeMarkup, wholeMarkup.text == text { return wholeMarkup.markup }
        let markup = MentionMarkup.whole(text)
        wholeMarkup = (text, markup)
        return markup
    }

    // MARK: Loading

    private func start(_ query: MentionQuery, directory: String?) {
        load?.cancel()
        generation += 1
        let generation = generation
        self.query = query
        self.directory = directory
        selectedID = nil

        let wanted = query.sources
        let limit = MentionRanker.matchLimit(for: query)
        var next: [MentionCandidate.Source: [RankedMention]] = [:]
        if wanted.contains(.files) { next[.files] = Self.narrowedFiles(results[.files], to: query.text, limit: limit) }
        if wanted.contains(.pullRequests) {
            next[.pullRequests] = Self.narrowedPullRequests(results[.pullRequests], to: query.text, limit: limit)
        }
        if wanted.contains(.linear) { next[.linear] = Self.narrowedLinear(results[.linear], to: query.text, limit: limit) }
        results = next
        pending = wanted
        publish()

        let sources = sources
        let debounce = debounce
        let sleep = sleep
        load = Task { [weak self] in
            await withTaskGroup(of: Answer.self) { group in
                if wanted.contains(.files) {
                    group.addTask { @MainActor in Answer(.files, await sources.files(for: query, in: directory)) }
                }
                if wanted.contains(.linear) {
                    group.addTask { @MainActor in
                        Answer(.linear, await sources.cachedLinearIssues(matching: query.text, limit: limit), isFinal: false)
                    }
                    group.addTask { @MainActor in
                        do { try await sleep(debounce.linearSearch) } catch { return Answer(.linear, nil) }
                        await sources.searchLinear(query.text)
                        if Task.isCancelled { return Answer(.linear, nil) }
                        return Answer(.linear, await sources.cachedLinearIssues(matching: query.text, limit: limit))
                    }
                }
                if wanted.contains(.pullRequests) {
                    let lookupDelay = Self.pullRequestLookupDelay(for: query.text, debounce: debounce)
                    group.addTask { @MainActor in
                        Answer(
                            .pullRequests,
                            await sources.pullRequests(for: query, in: directory, includingLookups: lookupDelay == nil),
                            isFinal: lookupDelay == nil
                        )
                    }
                    if let lookupDelay {
                        group.addTask { @MainActor in
                            do { try await sleep(lookupDelay) } catch { return Answer(.pullRequests, nil) }
                            return Answer(
                                .pullRequests,
                                await sources.pullRequests(for: query, in: directory, includingLookups: true)
                            )
                        }
                    }
                }
                for await answer in group {
                    self?.receive(answer, generation: generation)
                }
            }
        }
    }

    /// One source's rows. An answer that is not final updates the rows but
    /// leaves the source loading, and is dropped if the final one came first.
    private struct Answer: Sendable {
        let source: MentionCandidate.Source
        let ranked: [RankedMention]?
        let isFinal: Bool

        init(_ source: MentionCandidate.Source, _ ranked: [RankedMention]?, isFinal: Bool = true) {
            self.source = source
            self.ranked = ranked
            self.isFinal = isFinal
        }
    }

    private func receive(_ answer: Answer, generation: Int) {
        guard generation == self.generation, !Task.isCancelled else {
            didDiscard?()
            return
        }
        guard let ranked = answer.ranked, pending.contains(answer.source) else { return }
        results[answer.source] = ranked
        guard answer.isFinal else {
            publish()
            return
        }
        pending.remove(answer.source)
        publish()
        guard pending.isEmpty, let query else { return }
        if candidates.isEmpty, query.containsSpace {
            abandoned = (query.triggerLocation, query.text)
            close()
        }
        didSettle?()
    }

    private func publish() {
        guard let query else { return }
        let rows = MentionRanker.merge(results, isBare: query.isBare, isFiltered: query.filter != nil)
        let suggested = query.sources.count > 1 ? MentionRanker.suggestedFilters(for: query) : []
        let merged = query.sources.count > 1 ? MentionRanker.sectioned(rows, suggested: suggested) : rows
        if merged != candidates { candidates = merged }
        let index = MentionRanker.selectionIndex(keeping: selectedID, in: merged, suggested: suggested)
        if index != selectedIndex { selectedIndex = index }
        let loading = !pending.isEmpty
        if loading != isLoading { isLoading = loading }
    }

    private func close() {
        load?.cancel()
        load = nil
        generation += 1
        results = [:]
        pending = []
        selectedID = nil
        if query != nil { query = nil }
        if !candidates.isEmpty { candidates = [] }
        if selectedIndex != 0 { selectedIndex = 0 }
        if isLoading { isLoading = false }
    }

    /// `PullRequestMentionSource` may send a request for a number or a long
    /// enough title term, which is worth waiting out a burst of typing for.
    /// The open list answers at once in the meantime.
    private static func pullRequestLookupDelay(for text: String, debounce: Debounce) -> Duration? {
        var term = text.trimmingCharacters(in: .whitespaces)
        if term.hasPrefix("#") { term.removeFirst() }
        if PullRequestMentionSource.number(in: term) != nil { return debounce.pullRequestNumber }
        return term.count >= PullRequestMentionSource.minimumSearchLength ? debounce.pullRequestSearch : nil
    }

    private static func narrowedFiles(_ ranked: [RankedMention]?, to text: String, limit: Int) -> [RankedMention] {
        let entries = (ranked ?? []).compactMap { if case .file(let entry) = $0.candidate { entry } else { nil } }
        return entries.isEmpty ? [] : FileMentionMatcher.matches(text, in: entries, limit: limit)
    }

    private static func narrowedLinear(_ ranked: [RankedMention]?, to text: String, limit: Int) -> [RankedMention] {
        let issues = (ranked ?? []).compactMap { if case .linear(let issue) = $0.candidate { issue } else { nil } }
        return issues.isEmpty ? [] : LinearMentionMatcher.matches(text, in: issues, limit: limit)
    }

    private static func narrowedPullRequests(_ ranked: [RankedMention]?, to text: String, limit: Int) -> [RankedMention] {
        let pulls = (ranked ?? []).compactMap { if case .pullRequest(let pull) = $0.candidate { pull } else { nil } }
        return pulls.isEmpty ? [] : PullRequestMentionMatcher.matches(text, in: pulls, limit: limit)
    }

    // MARK: ComposerAutocompleteHandler

    func moveSelection(by delta: Int) {
        guard !candidates.isEmpty else { return }
        let count = candidates.count
        selectedIndex = ((selectedIndex + delta) % count + count) % count
        selectedID = candidates[selectedIndex].id
    }

    func select(_ index: Int) {
        guard candidates.indices.contains(index) else { return }
        selectedIndex = index
        acceptSelection()
    }

    func acceptSelection() {
        guard let query, candidates.indices.contains(selectedIndex) else { return }
        let candidate = candidates[selectedIndex]
        let accepted = MentionInsertion.accepting(candidate, query: query, in: text)
        if let (kind, resolution) = candidate.resolvedReference(homeDirectory: homeDirectory) {
            onResolve(kind, resolution)
        }
        let directory = lastInput?.directory ?? self.directory
        close()
        onAccept(accepted)
        if candidate.drillsIn {
            update(text: accepted.text, caretLocation: accepted.caretLocation, directory: directory, isCommandMode: false)
        } else {
            // The reference just typed would otherwise reopen the menu on
            // itself.
            dismissedTrigger = query.triggerLocation
        }
    }

    func dismiss() {
        dismissedTrigger = query?.triggerLocation
        close()
    }
}
