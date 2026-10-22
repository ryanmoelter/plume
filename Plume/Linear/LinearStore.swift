import AppKit
import Foundation
import Observation
import os
import Synchronization

/// Where `TranscriptStore` reports the Linear tool calls it finds.
protocol LinearActivitySink: AnyObject {
    func replaceActivity(tabID: UUID, evidence: [LinearEvidence])
    func forgetActivity(tabID: UUID)
}

/// The last rate-limit headers per account. The client reports them from
/// whatever thread the response lands on, so a lock rather than an actor hop
/// keeps the budget current before the fetch's own result is handled.
nonisolated final class LinearRateLimitBook: Sendable {
    private let limits = Mutex<[String: LinearRateLimit]>([:])

    func record(_ limit: LinearRateLimit, orgID: String) {
        limits.withLock { $0[orgID] = limit }
    }

    func limit(orgID: String) -> LinearRateLimit? {
        limits.withLock { $0[orgID] }
    }

    func remove(orgID: String) {
        limits.withLock { _ = $0.removeValue(forKey: orgID) }
    }

    func removeAll() {
        limits.withLock { $0.removeAll() }
    }
}

/// One identifier's state, boxed so a row is invalidated only by the issues
/// it reads.
@MainActor
@Observable
private final class LinearStateBox {
    var value: LinearIssueFetchState?
}

/// One tab's agent activity, boxed for the same reason as `LinearStateBox`.
@MainActor
@Observable
private final class LinearActivityBox {
    var evidence: [LinearEvidence] = []
}

/// Keeps every wanted Linear issue's state current across all connected
/// workspaces, and folds agent activity into each task's links.
///
/// Each workspace keeps a `LinearSyncCache` on disk, refreshed by a delta
/// sync of the issues updated since its cursor; rows read from it. Only an
/// identifier the cache lacks, or one due for verification, is looked up by
/// identifier, and only in the workspaces whose catalog has its team key,
/// batched per workspace with one request in flight each. A state outlives
/// its last owner, so a row a lazy list recycles comes back showing it rather
/// than loading. `docs/linear-sync.md` has the design.
@MainActor
@Observable
final class LinearStore: LinearActivitySink {
    static let shared = LinearStore(cacheDirectory: AppPaths.applicationSupport.appending(path: "linear"))

    static let syncInterval: TimeInterval = 45
    /// Activation syncs closer together than this are skipped, so switching
    /// apps back and forth spends no budget.
    static let activationSyncInterval: TimeInterval = 15
    /// How long a lookup's answer stands before a sync asks again. The delta
    /// sync sees every change but a permanent deletion, which only a lookup
    /// can find.
    static let verifyInterval: TimeInterval = 30 * 60
    /// Pages per delta sync. A longer delta resets the cache to what it fetched.
    static let maxDeltaPages = 5
    static let initialBackoff: TimeInterval = 30
    static let maxBackoff: TimeInterval = 15 * 60
    static let catalogMaxAge: TimeInterval = 6 * 60 * 60
    /// How often a manual link naming an unknown team key may refetch one
    /// workspace's catalog.
    static let catalogDemandInterval: TimeInterval = 5 * 60

    let accounts: LinearAccounts

    /// What rows read. Each box is written only when its value changes, and
    /// is kept once made so a view observing it never loses it.
    @ObservationIgnored private var stateBoxes: [String: LinearStateBox] = [:]
    @ObservationIgnored private var activityBoxes: [UUID: LinearActivityBox] = [:]
    private var catalogs: [String: LinearCatalog] = [:]
    private var accountStatuses: [String: LinearAccountStatus] = [:]
    private(set) var teamKeys: Set<String> = []

    /// Persists agent-started issues on the task owning the tab, returning
    /// false when no task owns it yet. Setting it reports anything already
    /// seen.
    @ObservationIgnored var onAgentStarted: ((UUID, Set<String>) -> Bool)? {
        didSet { reportStartedForEveryTab() }
    }

    @ObservationIgnored private var wantsByOwner: [UUID: Set<String>] = [:]
    @ObservationIgnored private var wantCounts: [String: Int] = [:]
    /// The workspace that answered with the issue, so a key two workspaces
    /// share is queried in both only until one finds it.
    @ObservationIgnored private var issueOwner: [String: String] = [:]
    @ObservationIgnored private var notFoundBy: [String: Set<String>] = [:]
    /// When a workspace last answered for the identifier, so a row coming
    /// back within a poll interval does not refetch.
    @ObservationIgnored private var answeredAt: [String: Date] = [:]
    @ObservationIgnored private var pending: [String: Set<String>] = [:]
    @ObservationIgnored private var scheduled: Set<String> = []
    @ObservationIgnored private var inFlight: Set<String> = []
    @ObservationIgnored private var catalogInFlight: Set<String> = []
    @ObservationIgnored private var caches: [String: LinearSyncCache] = [:]
    @ObservationIgnored private var cacheLoads: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var syncInFlight: Set<String> = []
    @ObservationIgnored private var syncFailures: [String: Int] = [:]
    @ObservationIgnored private var syncBackoffUntil: [String: Date] = [:]
    @ObservationIgnored private var diskSequence = 0
    @ObservationIgnored private var catalogFetchedAt: [String: Date] = [:]
    @ObservationIgnored private var lastCatalogDemand: [String: Date] = [:]
    @ObservationIgnored private var unauthorized: Set<String> = []
    @ObservationIgnored private var pausedUntil: [String: Date] = [:]
    @ObservationIgnored private var lastPolledAt: [String: Date] = [:]
    /// Bumped when an account's key changes or it is removed, so a request
    /// sent with the old key never applies its answer.
    @ObservationIgnored private var generations: [String: Int] = [:]
    @ObservationIgnored private var clients: [String: LinearClient] = [:]
    @ObservationIgnored private let rateLimits = LinearRateLimitBook()
    /// Write calls seen per tab, counted, so only a new one triggers an early
    /// refetch.
    @ObservationIgnored private var seenWrites: [UUID: [LinearEvidence: Int]] = [:]
    @ObservationIgnored private var reportedStarted: [UUID: Set<String>] = [:]
    @ObservationIgnored private var decodedLinks: [UUID: (data: Data?, links: LinearTaskLinks)] = [:]
    @ObservationIgnored private var branchCandidates: [String: [String]] = [:]
    @ObservationIgnored private var work: [Int: Task<Void, Never>] = [:]
    @ObservationIgnored private var nextWorkID = 0
    @ObservationIgnored private var pollTimer: Timer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var isStarted = false

    @ObservationIgnored private let disk: LinearCacheDisk?
    @ObservationIgnored private let now: () -> Date

    init(
        accounts: LinearAccounts? = nil,
        cacheDirectory: URL?,
        now: @escaping () -> Date = Date.init
    ) {
        let accounts = accounts ?? LinearAccounts()
        self.accounts = accounts
        disk = cacheDirectory.map { LinearCacheDisk(directory: $0) }
        self.now = now
        accounts.onChange = { [weak self] change in self?.accountsDidChange(change) }
    }

    // MARK: - Reading

    var isConfigured: Bool {
#if DEBUG
        if !fixtureTeamKeys.isEmpty { return true }
#endif
        return !accounts.accounts.isEmpty
    }

    func state(for identifier: String) -> LinearIssueFetchState? {
        stateBox(for: identifier.uppercased()).value
    }

    func accountStatus(orgID: String) -> LinearAccountStatus {
        accountStatuses[orgID] ?? .unknown
    }

    func catalog(orgID: String) -> LinearCatalog? {
        catalogs[orgID]
    }

    /// Not observable: read it when showing it.
    func rateLimit(orgID: String) -> LinearRateLimit? {
        rateLimits.limit(orgID: orgID)
    }

    /// Every issue the task links, classified. A view may call it from
    /// `body`: it writes only unobserved caches.
    func links(for task: WorkTask, branches: [String]) -> [LinkedLinearIssue] {
        let evidence = task.orderedTabs
            .filter { $0.kind == .agent }
            .flatMap { activityBox(for: $0.id).evidence }
        var candidates: [String] = []
        for branch in branches {
            for candidate in identifiers(inBranch: branch) where !candidates.contains(candidate) {
                candidates.append(candidate)
            }
        }
        return LinearLinkResolver.resolve(
            evidence: evidence,
            branchIdentifiers: candidates,
            links: links(of: task),
            catalogs: allCatalogs
        )
    }

    private func links(of task: WorkTask) -> LinearTaskLinks {
        let data = task.integrationsData
        if let cached = decodedLinks[task.id], cached.data == data { return cached.links }
        let links = TaskIntegrations.decode(data).linear ?? LinearTaskLinks()
        decodedLinks[task.id] = (data, links)
        return links
    }

    private func identifiers(inBranch branch: String) -> [String] {
        if let cached = branchCandidates[branch] { return cached }
        let candidates = LinearIdentifier.candidates(inBranch: branch)
        branchCandidates[branch] = candidates
        return candidates
    }

    private func stateBox(for identifier: String) -> LinearStateBox {
        if let box = stateBoxes[identifier] { return box }
        let box = LinearStateBox()
        stateBoxes[identifier] = box
        return box
    }

    private func activityBox(for tabID: UUID) -> LinearActivityBox {
        if let box = activityBoxes[tabID] { return box }
        let box = LinearActivityBox()
        activityBoxes[tabID] = box
        return box
    }

    private func currentState(_ identifier: String) -> LinearIssueFetchState? {
        stateBoxes[identifier]?.value
    }

    private func refreshTeamKeys() {
        var keys = catalogs.values.reduce(into: Set<String>()) { $0.formUnion($1.teamKeys) }
#if DEBUG
        keys.formUnion(fixtureTeamKeys)
#endif
        if keys != teamKeys { teamKeys = keys }
    }

    /// Catalogs in account order, which is the order a shared team key's
    /// workspaces are tried in.
    private var orderedCatalogs: [LinearCatalog] {
        accounts.accounts.compactMap { catalogs[$0.orgID] }
    }

    private var allCatalogs: [LinearCatalog] {
#if DEBUG
        guard !fixtureTeamKeys.isEmpty else { return orderedCatalogs }
        let fixture = LinearCatalog(
            orgID: "fixture",
            teams: fixtureTeamKeys.sorted().map { LinearTeam(id: $0, key: $0, name: $0, states: []) },
            fetchedAt: .distantPast
        )
        return orderedCatalogs + [fixture]
#else
        orderedCatalogs
#endif
    }

    // MARK: - Lifecycle

    /// Loads the disk caches, refreshes catalogs in the background, and
    /// starts syncing. Call once at launch.
    func start() {
        guard !isStarted else { return }
        isStarted = true
        for account in accounts.accounts {
            let orgID = account.orgID
            track { [self] in await ensureLoaded(orgID: orgID) }
            refreshCatalog(orgID: orgID)
        }

        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.stopPolling() }
            },
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.syncOnActivation()
                    self?.startPolling()
                }
            },
        ]
        startPolling()
    }

    private func startPolling() {
        guard pollTimer == nil else { return }
        // A scheduled timer fires on the main run loop.
        pollTimer = Timer.scheduledTimer(withTimeInterval: Self.syncInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sync() }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// One sync tick: refreshes stale catalogs and runs a delta sync for
    /// every account with budget to spare and no backoff pending.
    func sync() {
        sync(skippingAccountsSyncedWithin: 0)
    }

    func syncOnActivation() {
        sync(skippingAccountsSyncedWithin: Self.activationSyncInterval)
    }

    private func sync(skippingAccountsSyncedWithin minimumAge: TimeInterval) {
        for account in accounts.accounts {
            let orgID = account.orgID
            if let last = lastPolledAt[orgID], now().timeIntervalSince(last) < minimumAge { continue }
            lastPolledAt[orgID] = now()
            let fetchedAt = catalogFetchedAt[orgID] ?? .distantPast
            if now().timeIntervalSince(fetchedAt) >= Self.catalogMaxAge { refreshCatalog(orgID: orgID) }
            guard blocker(orgID: orgID) == nil, !isLowOnBudget(orgID: orgID) else { continue }
            if let until = syncBackoffUntil[orgID], until > now() { continue }
            syncIssues(orgID: orgID)
        }
    }

    // MARK: - Wants

    /// Replaces what `owner` wants fetched. An empty set releases it.
    func setWanted(_ identifiers: Set<String>, owner: UUID) {
        let wanted = Set(identifiers.map { $0.uppercased() })
        let previous = wantsByOwner[owner] ?? []
        guard wanted != previous else { return }
        wantsByOwner[owner] = wanted.isEmpty ? nil : wanted

        for identifier in previous.subtracting(wanted) { release(identifier) }
        var added: [String] = []
        for identifier in wanted.subtracting(previous) {
            wantCounts[identifier, default: 0] += 1
            if wantCounts[identifier] == 1 { added.append(identifier) }
        }
        var lookups: [String] = []
        for identifier in added where !isFixture(identifier) {
            if targets(for: identifier).isEmpty {
                lookups.append(identifier)
                continue
            }
            if publishFromCache(identifier) { continue }
            let current = currentState(identifier)
            if current == nil || current == .noWorkspace { publish(.loading, for: identifier) }
            if !isFresh(identifier) { lookups.append(identifier) }
        }
        request(lookups)
    }

    /// Stops fetching an identifier no one wants, keeping its last state.
    private func release(_ identifier: String) {
        guard let count = wantCounts[identifier] else { return }
        if count > 1 {
            wantCounts[identifier] = count - 1
            return
        }
        wantCounts.removeValue(forKey: identifier)
        notFoundBy.removeValue(forKey: identifier)
    }

    private func isFresh(_ identifier: String) -> Bool {
        guard currentState(identifier) != nil, let answered = answeredAt[identifier] else { return false }
        return now().timeIntervalSince(answered) < Self.verifyInterval
    }

    /// The first target workspace whose cache holds `identifier`.
    private func cachedIssue(_ identifier: String) -> (orgID: String, issue: LinearIssue)? {
        for orgID in targets(for: identifier) {
            if let issue = caches[orgID]?.issue(identifier: identifier) { return (orgID, issue) }
        }
        return nil
    }

    /// Publishes the cached issue, marked stale while its workspace cannot be
    /// asked. False when no target's cache has it.
    private func publishFromCache(_ identifier: String) -> Bool {
        guard let (orgID, issue) = cachedIssue(identifier) else { return false }
        issueOwner[identifier] = orgID
        notFoundBy.removeValue(forKey: identifier)
        if let blocker = blocker(orgID: orgID) {
            publish(.stale(issue, reason: blocker.localizedDescription), for: identifier)
        } else {
            publish(.issue(issue), for: identifier)
        }
        return true
    }

    /// Fetches a manual link's team key's catalogs, for a key no catalog has
    /// yet. Each workspace answers at most once per `catalogDemandInterval`.
    func refreshCatalogIfUnknown(teamKey: String) {
        guard !teamKeys.contains(teamKey.uppercased()) else { return }
        for account in accounts.accounts {
            let orgID = account.orgID
            if let last = lastCatalogDemand[orgID], now().timeIntervalSince(last) < Self.catalogDemandInterval { continue }
            lastCatalogDemand[orgID] = now()
            refreshCatalog(orgID: orgID)
        }
    }

    // MARK: - Fetching

    private func targets(for identifier: String) -> [String] {
        let owners = LinearAccounts.owners(
            ofTeamKey: LinearIdentifier.teamKey(of: identifier),
            catalogs: orderedCatalogs
        )
        if let owner = issueOwner[identifier], owners.contains(owner) { return [owner] }
        return owners
    }

    private func request(_ identifiers: some Sequence<String>) {
        for identifier in identifiers {
            let targets = targets(for: identifier)
            guard !targets.isEmpty else {
                publish(.noWorkspace, for: identifier)
                continue
            }
            if issueOwner[identifier] == nil { notFoundBy[identifier] = [] }
            for orgID in targets {
                pending[orgID, default: []].insert(identifier)
                scheduleFetch(orgID: orgID)
            }
        }
    }

    /// One fetch per account per turn of the run loop, however many rows asked.
    private func scheduleFetch(orgID: String) {
        guard scheduled.insert(orgID).inserted else { return }
        track { [self] in
            await Task.yield()
            guard !Task.isCancelled else { return }
            scheduled.remove(orgID)
            fetch(orgID: orgID)
        }
    }

    private func fetch(orgID: String) {
        // Anything still pending is picked up when the request in flight ends.
        guard !inFlight.contains(orgID) else { return }
        let identifiers = (pending.removeValue(forKey: orgID) ?? [])
            .filter { wantCounts[$0] != nil && targets(for: $0).contains(orgID) }
            .sorted()
        guard !identifiers.isEmpty else { return }

        if blocker(orgID: orgID) != nil {
            for identifier in identifiers { publishIfUnanswerable(identifier) }
            return
        }

        inFlight.insert(orgID)
        let generation = generation(orgID: orgID)
        let client = client(for: orgID)
        track { [self] in
            let result: Result<[String: LinearIssueLookup], Error>
            do {
                result = .success(try await client.fetchIssues(identifiers))
            } catch {
                result = .failure(error)
            }
            guard isCurrent(generation, orgID: orgID) else { return }
            inFlight.remove(orgID)
            switch result {
            case .success(let byIdentifier):
                setStatus(.connected, orgID: orgID)
                for identifier in identifiers {
                    switch byIdentifier[identifier] {
                    case .found(let snapshot):
                        applyFound(snapshot, identifier: identifier, orgID: orgID)
                    case .failed(let message):
                        applyFailure(LinearError.failed(message), identifier: identifier, orgID: orgID)
                    case .notFound, nil:
                        applyNotFound(identifier: identifier, orgID: orgID)
                    }
                }
                saveIssues(orgID: orgID)
            case .failure(let error):
                record(error, orgID: orgID)
                for identifier in identifiers {
                    applyFailure(error, identifier: identifier, orgID: orgID)
                }
            }
            if !(pending[orgID]?.isEmpty ?? true) { scheduleFetch(orgID: orgID) }
        }
    }

    private func applyFound(_ snapshot: LinearIssueSnapshot, identifier: String, orgID: String) {
        caches[orgID, default: LinearSyncCache(orgID: orgID)].upsert(snapshot, requestedAs: identifier)
        guard wantCounts[identifier] != nil else { return }
        if let owner = issueOwner[identifier], owner != orgID { return }
        issueOwner[identifier] = orgID
        notFoundBy.removeValue(forKey: identifier)
        answeredAt[identifier] = now()
        publish(.issue(caches[orgID]?.issue(identifier: identifier) ?? snapshot.issue), for: identifier)
    }

    private func applyFailure(_ error: any Error, identifier: String, orgID: String) {
        guard wantCounts[identifier] != nil else { return }
        if let owner = issueOwner[identifier], owner != orgID { return }
        publishFailure(error, for: identifier)
    }

    private func applyNotFound(identifier: String, orgID: String) {
        caches[orgID]?.removeIssue(identifier: identifier)
        guard wantCounts[identifier] != nil else { return }
        if let owner = issueOwner[identifier] {
            guard owner == orgID else { return }
            // The issue moved or was deleted; ask the other workspaces again.
            issueOwner.removeValue(forKey: identifier)
            notFoundBy[identifier] = [orgID]
            let others = targets(for: identifier).filter { $0 != orgID }
            guard others.isEmpty else {
                for other in others {
                    pending[other, default: []].insert(identifier)
                    scheduleFetch(orgID: other)
                }
                return
            }
        } else {
            notFoundBy[identifier, default: []].insert(orgID)
        }
        publishIfUnanswerable(identifier)
    }

    /// Once every target has said not found or cannot be asked, publishes
    /// `.notFound` or the first blocker. Until then a shared team key waits
    /// for the workspaces still answering.
    private func publishIfUnanswerable(_ identifier: String) {
        let targets = targets(for: identifier)
        guard !targets.isEmpty else { return }
        let notFound = notFoundBy[identifier] ?? []
        var firstBlocker: LinearError?
        for orgID in targets where !notFound.contains(orgID) {
            guard let blocker = blocker(orgID: orgID) else { return }
            firstBlocker = firstBlocker ?? blocker
        }
        if let firstBlocker {
            publishFailure(firstBlocker, for: identifier)
        } else {
            answeredAt[identifier] = now()
            publish(.notFound, for: identifier)
        }
    }

    private func publishFailure(_ error: any Error, for identifier: String) {
        if let issue = currentState(identifier)?.issue {
            publish(.stale(issue, reason: error.localizedDescription), for: identifier)
        } else {
            publish(.failing(error), for: identifier)
        }
    }

    /// Why an account cannot be asked right now, if it cannot.
    private func blocker(orgID: String) -> LinearError? {
        if unauthorized.contains(orgID) { return .unauthorized }
        if let until = pausedUntil[orgID] {
            if until > now() { return .rateLimited(until: until) }
            pausedUntil.removeValue(forKey: orgID)
            if case .rateLimited = accountStatus(orgID: orgID) { setStatus(.connected, orgID: orgID) }
        }
        return nil
    }

    /// Below a tenth of the budget, polls wait for the reset so a row the
    /// user just opened still has requests to spend.
    private func isLowOnBudget(orgID: String) -> Bool {
        guard let limit = rateLimits.limit(orgID: orgID), now() < limit.resetAt else { return false }
        return limit.remaining * 10 < limit.limit
    }

    private func record(_ error: any Error, orgID: String) {
        switch error as? LinearError {
        case .unauthorized:
            unauthorized.insert(orgID)
            setStatus(.unauthorized, orgID: orgID)
        case .rateLimited(let until):
            pausedUntil[orgID] = until
            setStatus(.rateLimited(until: until), orgID: orgID)
        case .failed(let message):
            setStatus(.failed(message), orgID: orgID)
        case nil:
            if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
            setStatus(.failed(error.localizedDescription), orgID: orgID)
        }
    }

    private func client(for orgID: String) -> LinearClient {
        if let client = clients[orgID] { return client }
        let book = rateLimits
        let client = accounts.makeClient(orgID: orgID) { book.record($0, orgID: orgID) }
        clients[orgID] = client
        return client
    }

    // MARK: - Catalogs

    func refreshCatalog(orgID: String) {
        guard !unauthorized.contains(orgID), catalogInFlight.insert(orgID).inserted else { return }
        let generation = generation(orgID: orgID)
        let client = client(for: orgID)
        let fetchedAt = now()
        track { [self] in
            let result: Result<LinearCatalog, Error>
            do {
                result = .success(try await client.fetchCatalog())
            } catch {
                result = .failure(error)
            }
            guard isCurrent(generation, orgID: orgID) else { return }
            catalogInFlight.remove(orgID)
            switch result {
            case .success(let fetched):
                let catalog = LinearCatalog(orgID: orgID, teams: fetched.teams, fetchedAt: fetchedAt)
                setStatus(.connected, orgID: orgID)
                install(catalog)
                save(catalog)
            case .failure(let error):
                record(error, orgID: orgID)
            }
        }
    }

    private func install(_ catalog: LinearCatalog) {
        catalogFetchedAt[catalog.orgID] = catalog.fetchedAt
        caches[catalog.orgID]?.install(catalog)
        guard catalogs[catalog.orgID]?.teams != catalog.teams else { return }
        catalogs[catalog.orgID] = catalog
        refreshTeamKeys()
        catalogsDidChange()
    }

    /// A catalog decides both routing and whether a requested state means
    /// "started", so a change re-evaluates every want and every tab.
    private func catalogsDidChange() {
        var routable: [String] = []
        for identifier in wantCounts.keys where !isFixture(identifier) {
            if targets(for: identifier).isEmpty {
                publish(.noWorkspace, for: identifier)
            } else if publishFromCache(identifier) {
                continue
            } else if currentState(identifier) == nil || currentState(identifier) == .noWorkspace {
                publish(.loading, for: identifier)
                routable.append(identifier)
            }
        }
        request(routable)
        reportStartedForEveryTab()
    }

    // MARK: - Delta sync

    private func syncIssues(orgID: String) {
        guard syncInFlight.insert(orgID).inserted else { return }
        let generation = generation(orgID: orgID)
        let client = client(for: orgID)
        track { [self] in
            await ensureLoaded(orgID: orgID)
            guard isCurrent(generation, orgID: orgID) else { return }
            let since = (caches[orgID] ?? LinearSyncCache(orgID: orgID)).deltaLowerBound(now: now())
            let result: Result<LinearDelta, Error>
            do {
                result = .success(try await LinearDelta.fetch(from: client, since: since, maxPages: Self.maxDeltaPages))
            } catch {
                result = .failure(error)
            }
            guard isCurrent(generation, orgID: orgID) else { return }
            syncInFlight.remove(orgID)
            switch result {
            case .success(let delta):
                syncFailures.removeValue(forKey: orgID)
                syncBackoffUntil.removeValue(forKey: orgID)
                setStatus(.connected, orgID: orgID)
                caches[orgID, default: LinearSyncCache(orgID: orgID)]
                    .applyDelta(delta.issues, complete: delta.isComplete, queriedFrom: since)
                saveIssues(orgID: orgID)
                republishWanted(orgID: orgID)
                verifyWanted(orgID: orgID)
            case .failure(let error):
                record(error, orgID: orgID)
                if case .failed? = error as? LinearError { backOff(orgID: orgID) }
                for identifier in wantedIdentifiers(targeting: orgID) where issueOwner[identifier] == orgID {
                    publishFailure(error, for: identifier)
                }
            }
        }
    }

    private func wantedIdentifiers(targeting orgID: String) -> [String] {
        wantCounts.keys.filter { !isFixture($0) && targets(for: $0).contains(orgID) }
    }

    private func republishWanted(orgID: String) {
        for identifier in wantedIdentifiers(targeting: orgID) { _ = publishFromCache(identifier) }
    }

    /// Looks up what the cache cannot vouch for: wanted identifiers it lacks
    /// whose last answer has expired, ones it held until this sync dropped
    /// them, and cached ones not verified within `verifyInterval`.
    private func verifyWanted(orgID: String) {
        let cache = caches[orgID]
        var lookups: [String] = []
        for identifier in wantedIdentifiers(targeting: orgID) {
            let isCached = cache?.issueID(identifier: identifier) != nil
            let wasDropped = !isCached && issueOwner[identifier] == orgID
            let isMissing = !isCached && cachedIssue(identifier) == nil
            if wasDropped || ((isCached || isMissing) && !isFresh(identifier)) {
                lookups.append(identifier)
            }
        }
        guard !lookups.isEmpty else { return }
        pending[orgID, default: []].formUnion(lookups)
        scheduleFetch(orgID: orgID)
    }

    private func backOff(orgID: String) {
        let failures = syncFailures[orgID, default: 0] + 1
        syncFailures[orgID] = failures
        let delay = min(Self.maxBackoff, Self.initialBackoff * pow(2, Double(failures - 1)))
        syncBackoffUntil[orgID] = now().addingTimeInterval(delay)
    }

    // MARK: - Disk

    /// Reads a workspace's catalog and issue cache once, folding them under
    /// whatever the network has already answered.
    private func ensureLoaded(orgID: String) async {
        guard let disk else { return }
        if let load = cacheLoads[orgID] {
            await load.value
            return
        }
        let load = Task { [weak self] in
            async let catalog = disk.loadCatalog(orgID: orgID)
            async let issues = disk.loadIssues(orgID: orgID)
            let loaded = await (catalog, issues)
            guard let self, !Task.isCancelled,
                  self.accounts.accounts.contains(where: { $0.orgID == orgID })
            else { return }
            self.installLoaded(orgID: orgID, catalog: loaded.0, issues: loaded.1)
        }
        cacheLoads[orgID] = load
        await load.value
    }

    private func installLoaded(orgID: String, catalog: LinearCatalog?, issues: LinearSyncCache?) {
        if let issues {
            var merged = issues
            if let held = caches[orgID] {
                merged = held
                merged.absorb(issues)
            }
            caches[orgID] = merged
        }
        if let catalog, catalogs[orgID] == nil {
            install(catalog)
        } else if let catalog = catalogs[orgID] {
            caches[orgID]?.install(catalog)
        }
        if issues != nil { republishWanted(orgID: orgID) }
    }

    private func save(_ catalog: LinearCatalog) {
        guard let disk else { return }
        let sequence = nextDiskSequence()
        track { await disk.save(catalog, sequence: sequence) }
    }

    /// Prunes to what is worth keeping, then writes off the main thread.
    private func saveIssues(orgID: String) {
        guard let disk, var cache = caches[orgID] else { return }
        cache.prune(keeping: Set(wantCounts.keys), now: now())
        caches[orgID] = cache
        let sequence = nextDiskSequence()
        track { await disk.save(cache, sequence: sequence) }
    }

    private func nextDiskSequence() -> Int {
        diskSequence += 1
        return diskSequence
    }

    // MARK: - Accounts

    private func accountsDidChange(_ change: LinearAccounts.Change) {
        switch change {
        case .keyChanged(let orgID):
            invalidate(orgID: orgID)
            rateLimits.remove(orgID: orgID)
            setStatus(.unknown, orgID: orgID)
            refreshCatalog(orgID: orgID)
            request(wantCounts.keys.filter { !isFixture($0) && targets(for: $0).contains(orgID) })
        case .removed(let orgID):
            invalidate(orgID: orgID)
            catalogFetchedAt.removeValue(forKey: orgID)
            pending.removeValue(forKey: orgID)
            clients.removeValue(forKey: orgID)
            rateLimits.remove(orgID: orgID)
            accountStatuses.removeValue(forKey: orgID)
            let owned = issueOwner.filter { $0.value == orgID }.keys
            for identifier in owned { issueOwner.removeValue(forKey: identifier) }
            for (identifier, box) in stateBoxes where wantCounts[identifier] == nil && !isFixture(identifier) {
                box.value = nil
            }
            caches.removeValue(forKey: orgID)
            cacheLoads.removeValue(forKey: orgID)?.cancel()
            if let disk {
                let sequence = nextDiskSequence()
                track { await disk.remove(orgID: orgID, sequence: sequence) }
            }
            if catalogs.removeValue(forKey: orgID) != nil {
                refreshTeamKeys()
                catalogsDidChange()
            }
            // A shared key still waiting on the removed workspace's answer
            // would otherwise sit at loading until the next poll.
            let waiting = wantCounts.keys.filter {
                !isFixture($0) && issueOwner[$0] == nil && currentState($0) == .loading
            }
            request(Set(owned.filter { wantCounts[$0] != nil } + waiting).sorted())
        }
    }

    /// Forgets everything the old key learned and drops its requests in
    /// flight, whose answers `isCurrent` then discards.
    private func invalidate(orgID: String) {
        generations[orgID, default: 0] += 1
        inFlight.remove(orgID)
        catalogInFlight.remove(orgID)
        syncInFlight.remove(orgID)
        syncFailures.removeValue(forKey: orgID)
        syncBackoffUntil.removeValue(forKey: orgID)
        unauthorized.remove(orgID)
        pausedUntil.removeValue(forKey: orgID)
        lastCatalogDemand.removeValue(forKey: orgID)
        lastPolledAt.removeValue(forKey: orgID)
        answeredAt.removeAll()
    }

    private func generation(orgID: String) -> Int {
        generations[orgID, default: 0]
    }

    /// Whether a completion may apply: neither cancelled by `reset` nor sent
    /// with a key since changed or removed.
    private func isCurrent(_ generation: Int, orgID: String) -> Bool {
        !Task.isCancelled && self.generation(orgID: orgID) == generation
    }

    private func setStatus(_ status: LinearAccountStatus, orgID: String) {
        guard accountStatus(orgID: orgID) != status else { return }
        accountStatuses[orgID] = status
    }

    // MARK: - Agent activity

    func replaceActivity(tabID: UUID, evidence: [LinearEvidence]) {
        let box = activityBox(for: tabID)
        if box.evidence != evidence { box.evidence = evidence }

        // A write counts once its result is in, so the refetch reads what it wrote.
        var writes: [LinearEvidence: Int] = [:]
        for item in evidence where item.isWrite && item.outcome == .succeeded {
            writes[item, default: 0] += 1
        }
        let seen = seenWrites[tabID] ?? [:]
        let fresh = writes.filter { $0.value > seen[$0.key, default: 0] }.keys
        seenWrites[tabID] = writes.isEmpty ? nil : writes
        let refetch = Set(fresh.map { $0.identifier.uppercased() })
            .filter { wantCounts[$0] != nil && !isFixture($0) }
        request(refetch.sorted())

        reportStarted(tabID: tabID)
    }

    func forgetActivity(tabID: UUID) {
        if let box = activityBoxes[tabID], !box.evidence.isEmpty { box.evidence = [] }
        seenWrites.removeValue(forKey: tabID)
        reportedStarted.removeValue(forKey: tabID)
    }

    private func reportStartedForEveryTab() {
        for (tabID, box) in activityBoxes where !box.evidence.isEmpty { reportStarted(tabID: tabID) }
    }

    /// Reports each identifier at most once per tab, counting a report only
    /// once a task has taken it.
    private func reportStarted(tabID: UUID) {
        guard let onAgentStarted, let evidence = activityBoxes[tabID]?.evidence, !evidence.isEmpty else { return }
        let started = LinearLinkResolver.startedIdentifiers(evidence: evidence, catalogs: allCatalogs)
        let new = started.subtracting(reportedStarted[tabID] ?? [])
        guard !new.isEmpty, onAgentStarted(tabID, new) else { return }
        reportedStarted[tabID, default: []].formUnion(new)
    }

    func forget(taskID: UUID) {
        decodedLinks.removeValue(forKey: taskID)
    }

    // MARK: - Bookkeeping

    private func publish(_ state: LinearIssueFetchState, for identifier: String) {
        guard wantCounts[identifier] != nil, currentState(identifier) != state else { return }
        stateBox(for: identifier).value = state
    }

    private func track(_ operation: @escaping @MainActor () async -> Void) {
        let id = nextWorkID
        nextWorkID += 1
        work[id] = Task { [weak self] in
            await operation()
            self?.work.removeValue(forKey: id)
        }
    }

    /// Awaits every fetch in flight, including any they start. For tests.
    func settle() async {
        while !work.isEmpty {
            let pending = work.values
            work.removeAll()
            for task in pending { await task.value }
        }
    }

    /// Drops everything but the accounts. For tests.
    func reset() {
        for task in work.values { task.cancel() }
        work.removeAll()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        stopPolling()
        isStarted = false
        stateBoxes.removeAll()
        activityBoxes.removeAll()
        catalogs.removeAll()
        accountStatuses.removeAll()
        wantsByOwner.removeAll()
        wantCounts.removeAll()
        issueOwner.removeAll()
        notFoundBy.removeAll()
        answeredAt.removeAll()
        lastPolledAt.removeAll()
        decodedLinks.removeAll()
        branchCandidates.removeAll()
        pending.removeAll()
        scheduled.removeAll()
        inFlight.removeAll()
        catalogInFlight.removeAll()
        catalogFetchedAt.removeAll()
        caches.removeAll()
        for load in cacheLoads.values { load.cancel() }
        cacheLoads.removeAll()
        syncInFlight.removeAll()
        syncFailures.removeAll()
        syncBackoffUntil.removeAll()
        lastCatalogDemand.removeAll()
        unauthorized.removeAll()
        pausedUntil.removeAll()
        clients.removeAll()
        rateLimits.removeAll()
        seenWrites.removeAll()
        reportedStarted.removeAll()
#if DEBUG
        fixtureIdentifiers.removeAll()
        fixtureTeamKeys.removeAll()
#endif
        refreshTeamKeys()
    }

    private func isFixture(_ identifier: String) -> Bool {
#if DEBUG
        fixtureIdentifiers.contains(identifier)
#else
        false
#endif
    }

#if DEBUG
    @ObservationIgnored private var fixtureIdentifiers: Set<String> = []
    private var fixtureTeamKeys: Set<String> = []

    /// Publishes `state` for `identifier` with no network call, for the DEBUG
    /// sidebar fixture catalog.
    func seedFixture(identifier: String, state: LinearIssueFetchState) {
        let key = identifier.uppercased()
        fixtureIdentifiers.insert(key)
        stateBox(for: key).value = state
    }

    /// Team keys the fixture catalog treats as known, so its branches and
    /// links resolve without a connected workspace.
    func seedFixtureTeamKeys(_ keys: Set<String>) {
        fixtureTeamKeys.formUnion(keys.map { $0.uppercased() })
        refreshTeamKeys()
    }
#endif
}
