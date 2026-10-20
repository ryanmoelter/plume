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

/// Keeps every wanted Linear issue's state current across all connected
/// workspaces, and folds agent activity into each task's links.
///
/// An identifier is fetched only from the workspaces whose catalog has its
/// team key, batched per workspace with one request in flight each.
@MainActor
@Observable
final class LinearStore: LinearActivitySink {
    static let shared = LinearStore()

    static let pollInterval: TimeInterval = 180
    static let catalogMaxAge: TimeInterval = 6 * 60 * 60
    /// How often a manual link naming an unknown team key may refetch one
    /// workspace's catalog.
    static let catalogDemandInterval: TimeInterval = 5 * 60

    let accounts: LinearAccounts

    /// What rows read. Each is written only when its value changes.
    private var states: [String: LinearIssueFetchState] = [:]
    private var catalogs: [String: LinearCatalog] = [:]
    private var accountStatuses: [String: LinearAccountStatus] = [:]
    private var activity: [UUID: [LinearEvidence]] = [:]

    /// Persists agent-started issues on the task owning the tab. Setting it
    /// reports anything already seen.
    @ObservationIgnored var onAgentStarted: ((UUID, Set<String>) -> Void)? {
        didSet { for tabID in activity.keys { reportStarted(tabID: tabID) } }
    }

    @ObservationIgnored private var wantsByOwner: [UUID: Set<String>] = [:]
    @ObservationIgnored private var wantCounts: [String: Int] = [:]
    /// The workspace that answered with the issue, so a key two workspaces
    /// share is queried in both only until one finds it.
    @ObservationIgnored private var issueOwner: [String: String] = [:]
    @ObservationIgnored private var notFoundBy: [String: Set<String>] = [:]
    @ObservationIgnored private var pending: [String: Set<String>] = [:]
    @ObservationIgnored private var scheduled: Set<String> = []
    @ObservationIgnored private var inFlight: Set<String> = []
    @ObservationIgnored private var catalogInFlight: Set<String> = []
    @ObservationIgnored private var catalogFetchedAt: [String: Date] = [:]
    @ObservationIgnored private var lastCatalogDemand: [String: Date] = [:]
    @ObservationIgnored private var unauthorized: Set<String> = []
    @ObservationIgnored private var pausedUntil: [String: Date] = [:]
    @ObservationIgnored private var clients: [String: LinearClient] = [:]
    @ObservationIgnored private let rateLimits = LinearRateLimitBook()
    /// Write calls seen per tab, counted, so only a new one triggers an early
    /// refetch.
    @ObservationIgnored private var seenWrites: [UUID: [LinearEvidence: Int]] = [:]
    @ObservationIgnored private var reportedStarted: [UUID: Set<String>] = [:]
    @ObservationIgnored private var work: [Int: Task<Void, Never>] = [:]
    @ObservationIgnored private var nextWorkID = 0
    @ObservationIgnored private var pollTimer: Timer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var isStarted = false

    @ObservationIgnored private let cacheDirectory: URL?
    @ObservationIgnored private let now: () -> Date

    init(
        accounts: LinearAccounts? = nil,
        cacheDirectory: URL? = AppPaths.applicationSupport.appending(path: "linear"),
        now: @escaping () -> Date = Date.init
    ) {
        let accounts = accounts ?? LinearAccounts()
        self.accounts = accounts
        self.cacheDirectory = cacheDirectory
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

    var teamKeys: Set<String> {
        var keys = catalogs.values.reduce(into: Set<String>()) { $0.formUnion($1.teamKeys) }
#if DEBUG
        keys.formUnion(fixtureTeamKeys)
#endif
        return keys
    }

    func state(for identifier: String) -> LinearIssueFetchState? {
        states[identifier.uppercased()]
    }

    func accountStatus(orgID: String) -> LinearAccountStatus {
        accountStatuses[orgID] ?? .unknown
    }

    /// Every issue the task links, classified. Pure, so a view may call it
    /// from `body`.
    func links(for task: WorkTask, branches: [String]) -> [LinkedLinearIssue] {
        let evidence = task.orderedTabs
            .filter { $0.kind == .agent }
            .flatMap { activity[$0.id] ?? [] }
        let links = TaskIntegrations.decode(task.integrationsData).linear ?? LinearTaskLinks()
        var candidates: [String] = []
        for branch in branches {
            for candidate in LinearIdentifier.candidates(inBranch: branch) where !candidates.contains(candidate) {
                candidates.append(candidate)
            }
        }
        return LinearLinkResolver.resolve(
            evidence: evidence,
            branchIdentifiers: LinearIdentifier.filter(candidates, teamKeys: teamKeys),
            links: links,
            catalogs: allCatalogs
        )
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

    /// Loads cached catalogs, refreshes them in the background, and starts
    /// polling. Call once at launch.
    func start() {
        guard !isStarted else { return }
        isStarted = true
        loadCachedCatalogs()
        for account in accounts.accounts { refreshCatalog(orgID: account.orgID) }

        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.stopPolling() }
            },
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.poll()
                    self?.startPolling()
                }
            },
        ]
        startPolling()
    }

    private func startPolling() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// One poll tick: refreshes stale catalogs and refetches every account
    /// with something wanted and budget to spare.
    func poll() {
        for account in accounts.accounts {
            let orgID = account.orgID
            let fetchedAt = catalogFetchedAt[orgID] ?? .distantPast
            if now().timeIntervalSince(fetchedAt) >= Self.catalogMaxAge { refreshCatalog(orgID: orgID) }
            guard blocker(orgID: orgID) == nil, !isLowOnBudget(orgID: orgID) else { continue }
            let identifiers = wantCounts.keys.filter { !isFixture($0) && targets(for: $0).contains(orgID) }
            guard !identifiers.isEmpty else { continue }
            pending[orgID, default: []].formUnion(identifiers)
            scheduleFetch(orgID: orgID)
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
        for identifier in added where !isFixture(identifier) {
            if states[identifier] == nil, !targets(for: identifier).isEmpty {
                publish(.loading, for: identifier)
            }
        }
        request(added.filter { !isFixture($0) })
    }

    private func release(_ identifier: String) {
        guard let count = wantCounts[identifier] else { return }
        if count > 1 {
            wantCounts[identifier] = count - 1
            return
        }
        wantCounts.removeValue(forKey: identifier)
        issueOwner.removeValue(forKey: identifier)
        notFoundBy.removeValue(forKey: identifier)
        // A fixture outlives its row, which a lazy list recycles.
        if !isFixture(identifier) { states.removeValue(forKey: identifier) }
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

        if let blocker = blocker(orgID: orgID) {
            for identifier in identifiers where targets(for: identifier) == [orgID] {
                publishFailure(blocker, for: identifier)
            }
            return
        }

        inFlight.insert(orgID)
        let client = client(for: orgID)
        track { [self] in
            let result: Result<[String: LinearIssue?], Error>
            do {
                result = .success(try await client.fetchIssues(identifiers))
            } catch {
                result = .failure(error)
            }
            inFlight.remove(orgID)
            guard accounts.accounts.contains(where: { $0.orgID == orgID }) else { return }
            switch result {
            case .success(let byIdentifier):
                setStatus(.connected, orgID: orgID)
                for identifier in identifiers {
                    if let issue = byIdentifier[identifier] ?? nil {
                        applyFound(issue, identifier: identifier, orgID: orgID)
                    } else {
                        applyNotFound(identifier: identifier, orgID: orgID)
                    }
                }
            case .failure(let error):
                record(error, orgID: orgID)
                for identifier in identifiers {
                    guard wantCounts[identifier] != nil else { continue }
                    if let owner = issueOwner[identifier], owner != orgID { continue }
                    publishFailure(error, for: identifier)
                }
            }
            if !(pending[orgID]?.isEmpty ?? true) { scheduleFetch(orgID: orgID) }
        }
    }

    private func applyFound(_ issue: LinearIssue, identifier: String, orgID: String) {
        guard wantCounts[identifier] != nil else { return }
        if let owner = issueOwner[identifier], owner != orgID { return }
        issueOwner[identifier] = orgID
        notFoundBy.removeValue(forKey: identifier)
        publish(.issue(issue), for: identifier)
    }

    private func applyNotFound(identifier: String, orgID: String) {
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
        if Set(targets(for: identifier)).isSubset(of: notFoundBy[identifier] ?? []) {
            publish(.notFound, for: identifier)
        }
    }

    private func publishFailure(_ error: any Error, for identifier: String) {
        if let issue = states[identifier]?.issue {
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

    private func refreshCatalog(orgID: String) {
        guard !unauthorized.contains(orgID), catalogInFlight.insert(orgID).inserted else { return }
        let client = client(for: orgID)
        let fetchedAt = now()
        track { [self] in
            let result: Result<LinearCatalog, Error>
            do {
                result = .success(try await client.fetchCatalog())
            } catch {
                result = .failure(error)
            }
            catalogInFlight.remove(orgID)
            guard accounts.accounts.contains(where: { $0.orgID == orgID }) else { return }
            switch result {
            case .success(let fetched):
                let catalog = LinearCatalog(orgID: orgID, teams: fetched.teams, fetchedAt: fetchedAt)
                if accountStatus(orgID: orgID) == .unknown { setStatus(.connected, orgID: orgID) }
                install(catalog)
                saveCache(catalog)
            case .failure(let error):
                record(error, orgID: orgID)
            }
        }
    }

    private func install(_ catalog: LinearCatalog) {
        catalogFetchedAt[catalog.orgID] = catalog.fetchedAt
        guard catalogs[catalog.orgID]?.teams != catalog.teams else { return }
        catalogs[catalog.orgID] = catalog
        catalogsDidChange()
    }

    /// A catalog decides both routing and whether a requested state means
    /// "started", so a change re-evaluates every want and every tab.
    private func catalogsDidChange() {
        var routable: [String] = []
        for identifier in wantCounts.keys where !isFixture(identifier) {
            if targets(for: identifier).isEmpty {
                publish(.noWorkspace, for: identifier)
            } else if states[identifier] == nil || states[identifier] == .noWorkspace {
                publish(.loading, for: identifier)
                routable.append(identifier)
            }
        }
        request(routable)
        for tabID in activity.keys { reportStarted(tabID: tabID) }
    }

    private func cacheFile(orgID: String) -> URL? {
        cacheDirectory?.appending(path: "catalog-\(orgID).json")
    }

    private func loadCachedCatalogs() {
        for account in accounts.accounts {
            guard let file = cacheFile(orgID: account.orgID),
                  let data = try? Data(contentsOf: file),
                  let catalog = try? JSONDecoder().decode(LinearCatalog.self, from: data),
                  catalog.orgID == account.orgID
            else { continue }
            install(catalog)
        }
    }

    private func saveCache(_ catalog: LinearCatalog) {
        guard let directory = cacheDirectory, let file = cacheFile(orgID: catalog.orgID) else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(catalog).write(to: file, options: .atomic)
        } catch {
            Log.app.error("Could not cache the Linear catalog: \(error, privacy: .public)")
        }
    }

    // MARK: - Accounts

    private func accountsDidChange(_ change: LinearAccounts.Change) {
        switch change {
        case .keyChanged(let orgID):
            unauthorized.remove(orgID)
            pausedUntil.removeValue(forKey: orgID)
            lastCatalogDemand.removeValue(forKey: orgID)
            setStatus(.unknown, orgID: orgID)
            refreshCatalog(orgID: orgID)
            request(wantCounts.keys.filter { !isFixture($0) && targets(for: $0).contains(orgID) })
        case .removed(let orgID):
            unauthorized.remove(orgID)
            pausedUntil.removeValue(forKey: orgID)
            lastCatalogDemand.removeValue(forKey: orgID)
            catalogFetchedAt.removeValue(forKey: orgID)
            pending.removeValue(forKey: orgID)
            clients.removeValue(forKey: orgID)
            rateLimits.remove(orgID: orgID)
            accountStatuses.removeValue(forKey: orgID)
            for (identifier, owner) in issueOwner where owner == orgID {
                issueOwner.removeValue(forKey: identifier)
            }
            if let file = cacheFile(orgID: orgID) { try? FileManager.default.removeItem(at: file) }
            if catalogs.removeValue(forKey: orgID) != nil { catalogsDidChange() }
        }
    }

    private func setStatus(_ status: LinearAccountStatus, orgID: String) {
        guard accountStatus(orgID: orgID) != status else { return }
        accountStatuses[orgID] = status
    }

    // MARK: - Agent activity

    func replaceActivity(tabID: UUID, evidence: [LinearEvidence]) {
        let current = activity[tabID] ?? []
        if current != evidence { activity[tabID] = evidence.isEmpty ? nil : evidence }

        var writes: [LinearEvidence: Int] = [:]
        for item in evidence where item.tool == "save_issue" || item.tool == "update_issue" {
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
        activity.removeValue(forKey: tabID)
        seenWrites.removeValue(forKey: tabID)
        reportedStarted.removeValue(forKey: tabID)
    }

    /// Reports each identifier at most once per tab. Only marks one reported
    /// once a callback has taken it.
    private func reportStarted(tabID: UUID) {
        guard let onAgentStarted, let evidence = activity[tabID] else { return }
        let started = LinearLinkResolver.startedIdentifiers(evidence: evidence, catalogs: allCatalogs)
        let new = started.subtracting(reportedStarted[tabID] ?? [])
        guard !new.isEmpty else { return }
        reportedStarted[tabID, default: []].formUnion(new)
        onAgentStarted(tabID, new)
    }

    // MARK: - Bookkeeping

    private func publish(_ state: LinearIssueFetchState, for identifier: String) {
        guard wantCounts[identifier] != nil, states[identifier] != state else { return }
        states[identifier] = state
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
        states.removeAll()
        catalogs.removeAll()
        accountStatuses.removeAll()
        activity.removeAll()
        wantsByOwner.removeAll()
        wantCounts.removeAll()
        issueOwner.removeAll()
        notFoundBy.removeAll()
        pending.removeAll()
        scheduled.removeAll()
        inFlight.removeAll()
        catalogInFlight.removeAll()
        catalogFetchedAt.removeAll()
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
        states[key] = state
    }

    /// Team keys the fixture catalog treats as known, so its branches and
    /// links resolve without a connected workspace.
    func seedFixtureTeamKeys(_ keys: Set<String>) {
        fixtureTeamKeys.formUnion(keys.map { $0.uppercased() })
    }
#endif
}
