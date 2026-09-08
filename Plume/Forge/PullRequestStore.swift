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
        var state: PullRequestFetchState = .loading
    }

    private var watches: [String: Watch] = [:]
    /// Every resolution and fetch in flight, so a test can await the work a
    /// synchronous call kicked off.
    private var work: [Task<Void, Never>] = []
    /// Resolved once per repository — origin and trunk change far less often
    /// than either the branch or the pull requests.
    private var facts: [String: RepositoryFacts] = [:]
    private var inFlight: Set<String> = []
    private var pollTimer: Timer?

    private let client: ForgeClient
    /// The repository root and its origin/trunk facts for a directory.
    /// Injectable so tests need no repository on disk.
    private let resolve: @Sendable (String) async -> (repository: String, facts: RepositoryFacts)?
    /// Checks whose pending status should not count, keyed by repository.
    /// Injected so the settings layer owns the policy.
    var ignoredPendingChecks: @MainActor (String) -> Set<String> = { _ in [] }

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
        return watches[directory]?.state
    }

    /// The rollup a row should draw, with this repository's ignored checks
    /// already suppressed.
    func checkRollup(for directory: String?, of pullRequest: PullRequest) -> CheckRollup {
        let repository = directory.flatMap { watches[$0]?.repository }
        let ignored = repository.map { ignoredPendingChecks($0) } ?? []
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
        resolveRepository(directory)
        startPollingIfNeeded()
    }

    func release(_ directory: String) {
        guard var existing = watches[directory] else { return }
        existing.refCount -= 1
        if existing.refCount <= 0 {
            watches.removeValue(forKey: directory)
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
        let branch = gitState?.branch
        let hadBranch = watch.branch
        watch.branch = branch

        if let gitState, !gitState.hasUpstream {
            // A branch never pushed cannot have a pull request, so it costs no
            // request at all.
            watch.branch = branch
            watches[directory] = watch
            publish(.localOnly, for: directory)
            return
        }

        watches[directory] = watch
        guard branch != hadBranch, branch != nil else { return }
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
            // The branch arrives from `GitStateStore` through `apply`, which
            // may already have run; refreshing here covers the other order.
            refresh(repository: resolved.repository)
        }
    }

    private func refreshRepository(of directory: String) {
        guard let repository = watches[directory]?.repository else { return }
        refresh(repository: repository)
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
                    publish(.failed(error.localizedDescription), for: directory)
                }
            }
        }
    }

    private func track(_ operation: @escaping @MainActor () async -> Void) {
        work.append(Task { await operation() })
    }

    /// Awaits every resolution and fetch in flight, including any they start.
    /// For tests.
    func settle() async {
        while !work.isEmpty {
            let pending = work
            work.removeAll()
            for task in pending { await task.value }
        }
    }

    /// Assigning an equal value publishes an observable change and invalidates
    /// every row reading it, so an unchanged answer is dropped — see
    /// `GitStateStore.refresh`.
    private func publish(_ state: PullRequestFetchState, for directory: String) {
        guard let existing = watches[directory], existing.state != state else { return }
        watches[directory]?.state = state
    }

    /// Drops a directory's watch whatever its refcount, for a task being
    /// deleted out from under the row that took it.
    func forget(directory: String) {
        watches.removeValue(forKey: directory)
        if watches.isEmpty {
            pollTimer?.invalidate()
            pollTimer = nil
        }
    }

    /// Drops every watch. For tests.
    func reset() {
        watches.removeAll()
        facts.removeAll()
        inFlight.removeAll()
        pollTimer?.invalidate()
        pollTimer = nil
    }
}
