import Foundation
import Observation

/// Where mention candidates come from. Injected so tests can gate each
/// source's answer.
@MainActor
protocol MentionSources: AnyObject, Sendable {
    var teamKeys: Set<String> { get }
    func files(for query: MentionQuery, in directory: String?) async -> [RankedMention]
    func pullRequests(for query: MentionQuery, in directory: String?) async -> [RankedMention]
    /// The cache only, so it answers at once.
    func cachedLinearIssues(matching text: String) -> [RankedMention]
    /// Fills the cache with what a remote search finds.
    func searchLinear(_ text: String) async
}

@MainActor
final class LiveMentionSources: MentionSources {
    var teamKeys: Set<String> { LinearStore.shared.teamKeys }

    func files(for query: MentionQuery, in directory: String?) async -> [RankedMention] {
        await FileMentionIndex.shared.matches(for: query, in: directory)
    }

    func pullRequests(for query: MentionQuery, in directory: String?) async -> [RankedMention] {
        await PullRequestMentionSource.shared.matches(for: query, in: directory)
    }

    func cachedLinearIssues(matching text: String) -> [RankedMention] {
        LinearStore.shared.mentionCandidates(matching: text)
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
    }

    typealias Sleep = @MainActor (Duration) async throws -> Void

    private(set) var candidates: [MentionCandidate] = []
    private(set) var selectedIndex = 0
    private(set) var isLoading = false
    private(set) var query: MentionQuery?

    /// The panel is on screen, possibly with nothing but a loading footer.
    var isPresented: Bool { query != nil && (!candidates.isEmpty || isLoading) }

    /// There is a row to pick, so the composer's keys belong to the menu. A
    /// panel that is only loading takes none, so Return still sends.
    var isShowing: Bool { query != nil && !candidates.isEmpty }

    @ObservationIgnored var onAccept: (SlashCommandMatcher.AcceptedCommand) -> Void = { _ in }
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

        guard !isCommandMode, let query = Self.query(in: text, caretLocation: caretLocation) else {
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
           current.text == query.text, directory == self.directory {
            self.query = query
            return
        }
        start(query, directory: directory)
    }

    private static func query(in text: String, caretLocation: Int) -> MentionQuery? {
        guard text.contains(where: { $0 == "@" || $0 == "#" }) else { return nil }
        return MentionQuery.query(
            text: text,
            caretLocation: caretLocation,
            codeRanges: ComposerCodeRanges.codeRanges(in: text)
        )
    }

    // MARK: Loading

    private func start(_ query: MentionQuery, directory: String?) {
        load?.cancel()
        generation += 1
        let generation = generation
        self.query = query
        self.directory = directory
        selectedID = nil

        let wanted = Self.sources(for: query.scope)
        var next: [MentionCandidate.Source: [RankedMention]] = [:]
        if wanted.contains(.files) { next[.files] = Self.narrowedFiles(results[.files], to: query.text) }
        if wanted.contains(.pullRequests) {
            next[.pullRequests] = Self.narrowedPullRequests(results[.pullRequests], to: query.text)
        }
        if wanted.contains(.linear) { next[.linear] = sources.cachedLinearIssues(matching: query.text) }
        results = next
        pending = wanted
        publish()

        let sources = sources
        let debounce = debounce
        let sleep = sleep
        load = Task { [weak self] in
            await withTaskGroup(of: (MentionCandidate.Source, [RankedMention]?).self) { group in
                if wanted.contains(.files) {
                    group.addTask { @MainActor in (.files, await sources.files(for: query, in: directory)) }
                }
                if wanted.contains(.linear) {
                    group.addTask { @MainActor in
                        do { try await sleep(debounce.linearSearch) } catch { return (.linear, nil) }
                        await sources.searchLinear(query.text)
                        if Task.isCancelled { return (.linear, nil) }
                        return (.linear, sources.cachedLinearIssues(matching: query.text))
                    }
                }
                if wanted.contains(.pullRequests) {
                    group.addTask { @MainActor in
                        if Self.searchesPullRequestTitles(query.text) {
                            do { try await sleep(debounce.pullRequestSearch) } catch { return (.pullRequests, nil) }
                        }
                        return (.pullRequests, await sources.pullRequests(for: query, in: directory))
                    }
                }
                for await (source, ranked) in group {
                    self?.receive(ranked, from: source, generation: generation)
                }
            }
        }
    }

    private func receive(_ ranked: [RankedMention]?, from source: MentionCandidate.Source, generation: Int) {
        guard generation == self.generation, !Task.isCancelled else {
            didDiscard?()
            return
        }
        guard let ranked else { return }
        results[source] = ranked
        pending.remove(source)
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
        let merged = MentionRanker.merge(results, query: query.text, teamKeys: sources.teamKeys)
        if merged != candidates { candidates = merged }
        let index = MentionRanker.selectionIndex(keeping: selectedID, in: merged)
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

    private static func sources(for scope: MentionQuery.Scope) -> Set<MentionCandidate.Source> {
        switch scope {
        case .all: [.files, .linear, .pullRequests]
        case .files: [.files]
        case .pullRequests: [.pullRequests]
        }
    }

    /// `PullRequestMentionSource` sends a title search for these, which is
    /// worth waiting out a burst of typing for.
    private static func searchesPullRequestTitles(_ text: String) -> Bool {
        var term = text.trimmingCharacters(in: .whitespaces)
        if term.hasPrefix("#") { term.removeFirst() }
        return Int(term) == nil && term.count >= PullRequestMentionSource.minimumSearchLength
    }

    private static func narrowedFiles(_ ranked: [RankedMention]?, to text: String) -> [RankedMention] {
        let entries = (ranked ?? []).compactMap { if case .file(let entry) = $0.candidate { entry } else { nil } }
        return entries.isEmpty ? [] : FileMentionMatcher.matches(text, in: entries)
    }

    private static func narrowedPullRequests(_ ranked: [RankedMention]?, to text: String) -> [RankedMention] {
        let pulls = (ranked ?? []).compactMap { if case .pullRequest(let pull) = $0.candidate { pull } else { nil } }
        return pulls.isEmpty ? [] : PullRequestMentionMatcher.matches(text, in: pulls)
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
        let accepted = MentionInsertion.accepting(
            candidates[selectedIndex],
            query: query,
            in: text,
            homeDirectory: homeDirectory
        )
        close()
        onAccept(accepted)
    }

    func dismiss() {
        dismissedTrigger = query?.triggerLocation
        close()
    }
}
