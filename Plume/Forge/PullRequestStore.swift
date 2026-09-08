import Foundation
import Observation

/// Keeps each watched working directory's pull request state current.
///
/// Keyed by working directory for its callers, but batched by repository
/// underneath: the aliased GraphQL query answers many branches in one request,
/// so ten tasks in one repository cost one network round trip rather than ten.
@MainActor
@Observable
final class PullRequestStore {
    static let shared = PullRequestStore()

    /// Far slower than `GitStateStore`'s poll. Every tick is a network round
    /// trip against a rate-limited API, and a pull request's checks move on
    /// the scale of minutes, not seconds.
    static let pollInterval: TimeInterval = 180

    private struct Watch {
        var refCount: Int
        /// The repository this directory belongs to, once git has answered.
        var repository: String?
        var branch: String?
        /// A branch never pushed cannot have a pull request, so it is never
        /// fetched. Nil until git has answered.
        var hasUpstream: Bool?
    }

    /// Bookkeeping, deliberately not what rows read: `@Observable` tracks a
    /// whole dictionary, so a branch or refcount write here would invalidate
    /// every row even when its answer is unchanged.
    @ObservationIgnored private var watches: [String: Watch] = [:]
    /// What the rows read, written only when the answer actually changes.
    private var states: [String: PullRequestFetchState] = [:]
    /// Every resolution and fetch in flight, so a test can await the work a
    /// synchronous call kicked off.
    private var work: [Int: Task<Void, Never>] = [:]
    private var nextWorkID = 0
    /// Resolved once per repository — origin and trunk change far less often
    /// than either the branch or the pull requests.
    private var facts: [String: RepositoryFacts] = [:]
    private var inFlight: Set<String> = []
    private var scheduled: Set<String> = []
    private var pollTimer: Timer?

    private let client: ForgeClient
    /// The repository root and its origin/trunk facts for a directory.
    /// Injectable so tests need no repository on disk.
    private let resolve: @Sendable (String) async -> (repository: String, facts: RepositoryFacts)?
    /// Checks whose pending status should not count, keyed by repository.
    /// Injected so the settings layer owns the policy.
    var resolveIgnoredPendingChecks: @Sendable (String) async -> Set<String> = { _ in [] }
    /// Resolved once per repository and cached, because `checkRollup` is read
    /// from a view's `body` and must never block on a subprocess there.
    @ObservationIgnored private var ignoredPendingChecks: [String: Set<String>] = [:]

    init(
        client: ForgeClient = GitHubForgeClient.shared,
        resolve: @escaping @Sendable (String) async -> (repository: String, facts: RepositoryFacts)? = PullRequestStore.resolveWithGit
    ) {
        self.client = client
        self.resolve = resolve
    }

    static let resolveWithGit: @Sendable (String) async -> (repository: String, facts: RepositoryFacts)? = { directory in
        guard let root = await GitService.shared.repositoryRoot(containing: directory) else { return nil }
        return (root, await GitService.shared.repositoryFacts(in: root))
    }

    func state(for directory: String?) -> PullRequestFetchState? {
        guard let directory else { return nil }
        return states[directory]
    }

    /// The rollup a row should draw, with this repository's ignored checks
    /// already suppressed.
    func checkRollup(for directory: String?, of pullRequest: PullRequest) -> CheckRollup {
        let repository = directory.flatMap { watches[$0]?.repository }
        let ignored = repository.flatMap { ignoredPendingChecks[$0] } ?? []
        return pullRequest.checkRollup(ignoredWhenPending: ignored)
    }

    /// Begins watching a directory, or takes another reference to one already
    /// watched. Balance every call with `release(_:)`.
    func watch(_ directory: String) {
        if var existing = watches[directory] {
            existing.refCount += 1
            watches[directory] = existing
            return
        }
        watches[directory] = Watch(refCount: 1)
#if DEBUG
        // A fixture directory has no real repository underneath it, so a
        // resolution would only clobber the seeded state with `.loading`
        // then `.forgeUnsupported`. The row still takes a refcounted watch,
        // so `release` balances normally.
        if fixtureDirectories.contains(directory) { return }
#endif
        states[directory] = .loading
        resolveRepository(directory)
        startPollingIfNeeded()
    }

    func release(_ directory: String) {
        guard var existing = watches[directory] else { return }
        existing.refCount -= 1
        if existing.refCount <= 0 {
            watches.removeValue(forKey: directory)
#if DEBUG
            // A fixture outlives its row: the lazy `List` releases whatever
            // scrolls out of view, and dropping the seeded state there would
            // blank the row when it came back.
            if !fixtureDirectories.contains(directory) { states.removeValue(forKey: directory) }
#else
            states.removeValue(forKey: directory)
#endif
        } else {
            watches[directory] = existing
        }
        if watches.isEmpty {
            pollTimer?.invalidate()
            pollTimer = nil
        }
    }

    /// Feeds the branch `GitStateStore` already publishes, so a checkout
    /// updates the row without waiting out the poll. A second `.git` watcher
    /// would only duplicate that one.
    func apply(gitState: GitState?, for directory: String) {
        guard var watch = watches[directory] else { return }
        let hadBranch = watch.branch
        watch.branch = gitState?.branch
        watch.hasUpstream = gitState.map(\.hasUpstream)
        watches[directory] = watch

        if watch.hasUpstream == false {
            publish(.localOnly, for: directory)
            return
        }
        guard watch.branch != hadBranch, watch.branch != nil else { return }
        refreshRepository(of: directory)
    }

    private func startPollingIfNeeded() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshAll() }
        }
    }

    private func refreshAll() {
        for repository in Set(watches.values.compactMap(\.repository)) {
            refresh(repository: repository)
        }
    }

    private func resolveRepository(_ directory: String) {
        track { [self] in
            let resolved = await resolve(directory)
            guard watches[directory] != nil else { return }
            guard let resolved else {
                publish(.forgeUnsupported, for: directory)
                return
            }
            watches[directory]?.repository = resolved.repository
            facts[resolved.repository] = resolved.facts
            if ignoredPendingChecks[resolved.repository] == nil {
                ignoredPendingChecks[resolved.repository] =
                    await resolveIgnoredPendingChecks(resolved.repository)
            }
            // The branch arrives from `GitStateStore` through `apply`, which
            // may already have run; refreshing here covers the other order.
            //
            // Coalesced: the sidebar resolves every row at once, and a refresh
            // per resolution would send one request per directory — exactly
            // the batching this store exists to avoid.
            scheduleRefresh(repository: resolved.repository)
        }
    }

    private func refreshRepository(of directory: String) {
        guard let repository = watches[directory]?.repository else { return }
        scheduleRefresh(repository: repository)
    }

    /// One refresh per repository per turn of the run loop, whatever number of
    /// rows asked for one.
    private func scheduleRefresh(repository: String) {
        guard scheduled.insert(repository).inserted else { return }
        track { [self] in
            await Task.yield()
            scheduled.remove(repository)
            refresh(repository: repository)
        }
    }

    private func refresh(repository: String) {
        // One request per repository at a time. Without this a slow forge
        // would queue another behind every branch change.
        guard !inFlight.contains(repository) else { return }

        let directories = watches.filter { $0.value.repository == repository }
        guard !directories.isEmpty else { return }

        guard ForgeKind.sniffing(originURL: facts[repository]?.originURL) == .github else {
            for directory in directories.keys { publish(.forgeUnsupported, for: directory) }
            return
        }

        let trunk = facts[repository]?.defaultBranch
        var fetchable: [String: String] = [:]
        for (directory, watch) in directories {
            guard let branch = watch.branch else { continue }
            guard watch.hasUpstream == true else {
                if watch.hasUpstream == false { publish(.localOnly, for: directory) }
                continue
            }
            if branch == trunk {
                // A long-dead pull request that targeted the trunk would
                // otherwise surface on the trunk's own row.
                publish(.noPR, for: directory)
                continue
            }
            fetchable[directory] = branch
        }
        let branches = Array(Set(fetchable.values))
        guard !branches.isEmpty else { return }

        inFlight.insert(repository)
        track { [self] in
            let result: Result<[String: PullRequest?], Error>
            do {
                result = .success(try await client.fetchPullRequests(forBranches: branches, in: repository))
            } catch {
                result = .failure(error)
            }
            inFlight.remove(repository)
            for (directory, branch) in fetchable {
                guard watches[directory]?.branch == branch else { continue }
                switch result {
                case .success(let byBranch):
                    if let pullRequest = byBranch[branch] ?? nil {
                        publish(.pullRequest(pullRequest), for: directory)
                    } else {
                        publish(.noPR, for: directory)
                    }
                case .failure(let error):
                    publish(.failing(error), for: directory)
                }
            }
        }
    }

    private func track(_ operation: @escaping @MainActor () async -> Void) {
        let id = nextWorkID
        nextWorkID += 1
        work[id] = Task { [weak self] in
            await operation()
            self?.work.removeValue(forKey: id)
        }
    }

    /// Awaits every resolution and fetch in flight, including any they start.
    /// For tests.
    func settle() async {
        while !work.isEmpty {
            let pending = work.values
            work.removeAll()
            for task in pending { await task.value }
        }
    }

    /// Assigning an equal value publishes an observable change and invalidates
    /// every row reading it, so an unchanged answer is dropped — see
    /// `GitStateStore.refresh`.
    private func publish(_ state: PullRequestFetchState, for directory: String) {
        guard watches[directory] != nil, states[directory] != state else { return }
        states[directory] = state
    }

    /// Drops a directory's watch whatever its refcount, for a task being
    /// deleted out from under the row that took it.
    func forget(directory: String) {
        watches.removeValue(forKey: directory)
        states.removeValue(forKey: directory)
        if watches.isEmpty {
            pollTimer?.invalidate()
            pollTimer = nil
        }
    }

    /// Drops every watch. For tests.
    func reset() {
        for task in work.values { task.cancel() }
        work.removeAll()
        scheduled.removeAll()
        watches.removeAll()
        states.removeAll()
        facts.removeAll()
        inFlight.removeAll()
#if DEBUG
        fixtureDirectories.removeAll()
#endif
        pollTimer?.invalidate()
        pollTimer = nil
    }

#if DEBUG
    /// Directories the sidebar fixture catalog owns. `refresh(repository:)`
    /// and `resolveRepository(_:)` skip these, so a seeded state is never
    /// raced by a real (and here, nonexistent) repository resolution.
    @ObservationIgnored private var fixtureDirectories: Set<String> = []

    /// Force-publishes `state` for `directory` with no network call, for the
    /// DEBUG sidebar fixture catalog. Bypasses `watch(_:)` entirely, so a
    /// fixture directory needs no real git repository underneath it.
    func seedFixture(directory: String, state: PullRequestFetchState) {
        fixtureDirectories.insert(directory)
        states[directory] = state
    }
#endif
}
