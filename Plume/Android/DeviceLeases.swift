import Foundation
import Observation

/// This app's device leases, by the tab that owns them, for the sidebar.
@MainActor
@Observable
final class DeviceLeaseStore {
    static let shared = DeviceLeaseStore()

    private(set) var leasesByOwnerTab: [UUID: [DeviceLease]] = [:]

    func leases(ownedBy tabIDs: some Sequence<UUID>) -> [DeviceLease] {
        tabIDs.flatMap { leasesByOwnerTab[$0] ?? [] }
    }

    func publish(_ registry: DeviceRegistry, app: String) {
        var byTab: [UUID: [DeviceLease]] = [:]
        for (_, lease) in registry.devices.sorted(by: { $0.key < $1.key }) where lease.owner.app == app {
            if let tabID = lease.owner.tabID { byTab[tabID, default: []].append(lease) }
        }
        if byTab != leasesByOwnerTab { leasesByOwnerTab = byTab }
    }

    /// "emulator-5554 (Pixel_8)", one per lease.
    static func summary(_ leases: [DeviceLease]) -> String {
        leases.map { lease in
            let name = lease.serial ?? "a remote device"
            return (lease.avd ?? lease.model).map { "\(name) (\($0))" } ?? name
        }.joined(separator: ", ")
    }
}

/// Keeps this app's tab-owned leases in the shared registry in step with its tabs. It only ever
/// touches leases whose owner names this app's socket, so a debug build and the installed app
/// leave each other's alone. Registry I/O runs on a background queue, since a `plume` holding the
/// lock may be waiting on adb. `docs/device-leases.md` is the reference.
@MainActor
final class DeviceLeaseCoordinator {
    static let shared = DeviceLeaseCoordinator()

    static let reapInterval: Duration = .seconds(60)
    /// How long a quit waits for the registry lock.
    nonisolated static let terminationWait: TimeInterval = 2

    struct Effects {
        var endReservation: @MainActor (DeviceLease) -> Void = DeviceLeaseCoordinator.endReservation
        var closeTab: @MainActor (UUID) -> Void = { CLICommandHandler.shared.closeTab($0) }
        /// Returns a device tab to the picker, ending whatever it was reserving.
        var endTabReservation: @MainActor (UUID) -> Void = { DeviceSessionManager.shared.existingSession(for: $0)?.endReservation() }
        /// Ends a device tab's reservation but leaves the tab showing why.
        var abandonTabReservation: @MainActor (_ tab: UUID, _ reason: String) -> Void = {
            DeviceSessionManager.shared.existingSession(for: $0)?.abandonReservation(reason: $1)
        }
        var extendTabReservation: @MainActor (_ tab: UUID, _ until: Date) async throws -> Void = { tab, until in
            guard let session = DeviceSessionManager.shared.existingSession(for: tab) else {
                throw CLIFailure("the device tab holding the reservation is gone")
            }
            try await session.extendReservation(until: until)
        }
        /// Whether a tab is open in a task that isn't archived. An archived task's tabs come back
        /// with the same IDs when it is restored.
        var isTabLive: @MainActor (UUID) -> Bool = { CLICommandHandler.shared.hasLiveTab($0) }
    }

    let store: DeviceRegistryStore
    let leases: DeviceLeaseStore
    var effects: Effects
    /// The socket this app serves. Nil until `start`, and until then every call is a no-op.
    private(set) var appSocket: String?
    private let now: @Sendable () -> Date
    private let queue = DispatchQueue(label: "com.ryanmoelter.Plume.device-leases", qos: .utility)
    private var watcher: FileWatcher?
    private var reapTask: Task<Void, Never>?
    /// Claims whose device hasn't connected yet, by device tab. In memory only: a quit ends
    /// their reservations, and the launch sweep drops their pending entries.
    private var claims: [UUID: RemoteClaim] = [:]
    /// Tabs forgotten this run. Effects never touch one, and a lease that appears for one later,
    /// from a `plume` that was booting an emulator when its tab closed, is dropped.
    private var forgottenTabs: Set<UUID> = []

    init(
        store: DeviceRegistryStore = DeviceRegistryStore(),
        leases: DeviceLeaseStore = .shared,
        effects: Effects = Effects(),
        appSocket: String? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.leases = leases
        self.effects = effects
        self.appSocket = appSocket
        self.now = now
    }

    /// Clears what an earlier run left, then follows the registry and reaps on a timer.
    func start(appSocket: String, liveTabIDs: Set<UUID>) {
        guard self.appSocket == nil else { return }
        self.appSocket = appSocket
        sweepAtLaunch(liveTabIDs: liveTabIDs)
        // An empty file reads as an empty registry, and owning it avoids polling for it.
        let watcher = FileWatcher(url: URL(fileURLWithPath: store.registryFile), createsFile: true) { [weak self] in
            self?.refresh()
        }
        watcher.start()
        self.watcher = watcher
        reapTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.reapInterval)
                self?.reapExpired()
            }
        }
    }

    func refresh() {
        guard let app = appSocket else { return }
        let store = store
        queue.async { [self] in
            let registry: DeviceRegistry
            do {
                registry = try store.load()
            } catch {
                EmulatorLog.error("device leases: \(error)")
                return
            }
            self.onMain { coordinator in
                coordinator.leases.publish(registry, app: app)
                coordinator.dropLeasesOfForgottenTabs(in: registry, app: app)
            }
        }
    }

    /// A tab forgotten this run that hasn't come back, as an archived task's tabs do on a restore.
    private func isForgotten(_ tabID: UUID) -> Bool { forgottenTabs.contains(tabID) && !effects.isTabLive(tabID) }

    private func dropLeasesOfForgottenTabs(in registry: DeviceRegistry, app: String) {
        let owners = Set(registry.devices.values.compactMap { $0.owner.app == app ? $0.owner.tabID : nil })
        let stray = owners.filter(isForgotten)
        guard !stray.isEmpty else { return }
        mutate { registry, app, _ in stray.flatMap { registry.forget(tabID: $0, app: app) } }
    }

    /// The tab's own leases go, and a remote one ends its reservation. A lease whose device tab
    /// this was keeps going without it, unless it is remote: the reservation closed with the tab.
    func tabForgotten(_ tabID: UUID) {
        forgottenTabs.insert(tabID)
        claims[tabID] = nil
        for claim in claims.values where claim.owner.tabID == tabID {
            claims[claim.deviceTabID] = nil
            onMain { coordinator in
                // Archiving forgets the device tab too, and closing its session ended the reservation.
                guard !coordinator.isForgotten(claim.deviceTabID) else { return }
                if claim.deviceTabCreated {
                    coordinator.effects.closeTab(claim.deviceTabID)
                } else {
                    coordinator.effects.endTabReservation(claim.deviceTabID)
                }
            }
        }
        mutate { registry, app, _ in registry.forget(tabID: tabID, app: app) }
    }

    /// Records a pending claim before its reservation starts, so the claimant has something to
    /// wait on. The claim is held from before the write, so a concurrent request sees it at once,
    /// and a claimant tab forgotten during the write cancels it rather than leaking a reservation.
    func beginClaim(_ claim: RemoteClaim) async throws {
        guard claims[claim.deviceTabID] == nil else {
            throw CLIFailure("device tab \(claim.deviceTabID.uuidString) is already reserving")
        }
        claims[claim.deviceTabID] = claim
        do {
            try await perform { registry, _, now in registry.recordClaim(claim, now: now) }
        } catch {
            if claims[claim.deviceTabID]?.id == claim.id { claims[claim.deviceTabID] = nil }
            throw error
        }
        guard claims[claim.deviceTabID]?.id == claim.id else {
            mutate { registry, _, _ in
                registry.pending[DeviceRegistry.pendingKey(claim: claim.id)] = nil
                return []
            }
            throw CLIFailure("the claim's tab closed before the reservation started")
        }
    }

    func isClaiming(deviceTab: UUID) -> Bool { claims[deviceTab] != nil }

    /// A claim still reserving for `owner`, which a second request joins rather than doubling.
    func claim(ownedBy owner: DeviceLeaseOwner) -> RemoteClaim? {
        claims.values.first { $0.owner == owner }
    }

    /// Records `claim`'s pending entry again for a claimant joining it, since a long reservation
    /// can outlast the entry's expiry. Resumes once it is saved.
    func rejoin(_ claim: RemoteClaim) async throws {
        try await perform { registry, _, now in
            let leased = registry.devices.values.contains { $0.remote?.claimID == claim.id }
            if !leased, registry.pending[DeviceRegistry.pendingKey(claim: claim.id)] == nil {
                registry.recordClaim(claim, now: now)
            }
        }
    }

    /// Extends the reservation behind this app's remote lease at `key` to cover `ttl` from now.
    func extendLease(_ key: String, ttl: TimeInterval) async throws {
        let lease = try await perform { registry, app, _ in
            registry.devices[key].flatMap { $0.owner.app == app && $0.kind == .remote ? $0 : nil }
        }
        guard let lease else { throw CLIFailure("this Plume holds no remote lease on \(key)") }
        guard let deviceTab = lease.deviceTabID else { throw CLIFailure("\(key) has no device tab holding its reservation") }
        try await effects.extendTabReservation(deviceTab, now().addingTimeInterval(ttl))
    }

    /// Drops this app's lease at `key`, ending its reservation and closing a device tab the claim
    /// opened. Nil when this app holds no lease there.
    func releaseLease(_ key: String) async throws -> DeviceLease? {
        let lease = try await perform { registry, app, _ in registry.takeLease(key, app: app) }
        if let lease, lease.kind == .remote { release(lease) }
        return lease
    }

    /// A claim's device connecting becomes its lease. A reconnect moves the lease to the new adb
    /// port, and a reservation that ends takes its lease, or its pending claim, with it.
    func reservationEvent(_ event: DeviceSession.ReservationEvent, deviceTab: UUID) {
        let claim = claims.removeValue(forKey: deviceTab)
        switch event {
        case .attached(let reservationID, let serial):
            mutate { registry, app, now in
                if let claim {
                    registry.attach(claim, reservationID: reservationID, serial: serial, now: now)
                } else {
                    registry.reattach(reservationID: reservationID, serial: serial, app: app)
                }
                return []
            }
            if let claim { extendForClaim(claim) }
        case .failed(let message):
            guard let claim else { return }
            mutate { registry, _, _ in
                registry.failClaim(claim.id, message: message)
                return []
            }
            // A reservation can fail after it started billing, when its device never reaches adb.
            // The error is written first, so the claimant still reads it.
            onMain { coordinator in coordinator.effects.abandonTabReservation(deviceTab, message) }
        case .ended(let reservationID):
            mutate { registry, app, _ in
                if let reservationID { registry.dropRemoteLease(reservationID: reservationID, app: app) }
                if let claim { registry.failClaim(claim.id, message: "the reservation ended before the device connected") }
                return []
            }
        }
    }

    /// A claim's TTL can run past the reservation's own length, which would end the lease early.
    private func extendForClaim(_ claim: RemoteClaim) {
        let until = now().addingTimeInterval(claim.ttl)
        let extend = effects.extendTabReservation
        Task {
            do {
                try await extend(claim.deviceTabID, until)
            } catch {
                EmulatorLog.error("device leases: couldn't extend the reservation for \(claim.id): \(error.localizedDescription)")
            }
        }
    }

    /// A previous run's tabs are gone or dormant, and its reservations ended at quit or are
    /// swept by the ledger.
    func sweepAtLaunch(liveTabIDs: Set<UUID>) {
        mutate { registry, app, _ in
            registry.sweepAtLaunch(app: app, liveTabIDs: liveTabIDs)
            return []
        }
    }

    func reapExpired() {
        mutate { registry, app, now in registry.dropExpired(app: app, now: now) }
    }

    /// Blocks briefly; a lease left behind is dropped by the next launch's sweep.
    func dropRemoteLeasesForTermination() {
        guard let app = appSocket else { return }
        let store = store
        let done = DispatchSemaphore(value: 0)
        queue.async {
            defer { done.signal() }
            try? store.withLock {
                var registry = try store.load()
                if registry.dropRemote(app: app) { try store.save(registry) }
            }
        }
        _ = done.wait(timeout: .now() + Self.terminationWait)
    }

    /// Resumes once every operation queued so far has finished, its effects included.
    func settle() async {
        let queue = queue
        await withCheckedContinuation { continuation in
            queue.async { DispatchQueue.main.async { continuation.resume() } }
        }
    }

    /// Like `mutate`, for a caller that needs the outcome. Resumes once the change is saved.
    private func perform<T: Sendable>(
        _ change: @escaping @Sendable (inout DeviceRegistry, _ app: String, _ now: Date) -> T
    ) async throws -> T {
        guard let app = appSocket else { throw CLIFailure("this Plume isn't tracking device leases") }
        let (store, now) = (store, now)
        let outcome = try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try Self.apply(change, store: store, app: app, now: now()) })
            }
        }
        leases.publish(outcome.registry, app: app)
        return outcome.value
    }

    /// Loads under the lock, applies `change`, and saves when it changed anything.
    private nonisolated static func apply<T>(
        _ change: (inout DeviceRegistry, _ app: String, _ now: Date) -> T,
        store: DeviceRegistryStore,
        app: String,
        now: Date
    ) throws -> (registry: DeviceRegistry, value: T) {
        try store.withLock {
            var registry = try store.load()
            let before = registry
            let value = change(&registry, app, now)
            if registry != before { try store.save(registry) }
            return (registry, value)
        }
    }

    /// Runs `change` under the registry lock off the main actor, saves when it changed, then
    /// publishes and ends the reservations of the remote leases it returned.
    private func mutate(_ change: @escaping @Sendable (inout DeviceRegistry, _ app: String, _ now: Date) -> [DeviceLease]) {
        guard let app = appSocket else { return }
        let (store, now) = (store, now)
        queue.async { [self] in
            let outcome: (registry: DeviceRegistry, value: [DeviceLease])
            do {
                outcome = try Self.apply(change, store: store, app: app, now: now())
            } catch {
                EmulatorLog.error("device leases: \(error)")
                return
            }
            self.onMain { coordinator in
                coordinator.leases.publish(outcome.registry, app: app)
                for lease in outcome.value { coordinator.release(lease) }
            }
        }
    }

    private func release(_ lease: DeviceLease) {
        // A forgotten device tab's session ended the reservation when it closed.
        if let tabID = lease.deviceTabID, isForgotten(tabID) { return }
        EmulatorLog.info("device leases: ending \(lease.remote?.reservationID ?? "?") with its lease")
        effects.endReservation(lease)
        if lease.deviceTabCreatedByClaim, let tabID = lease.deviceTabID { effects.closeTab(tabID) }
    }

    /// `DispatchQueue.main` rather than a task, so `settle()` runs after it.
    private nonisolated func onMain(_ body: @escaping @MainActor @Sendable (DeviceLeaseCoordinator) -> Void) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                if let self { body(self) }
            }
        }
    }

    /// Through the device tab's session when it holds the reservation, which returns the tab to
    /// the picker; otherwise straight to Device Streaming.
    static func endReservation(_ lease: DeviceLease) {
        guard let remote = lease.remote else { return }
        if let tabID = lease.deviceTabID,
           let session = DeviceSessionManager.shared.existingSession(for: tabID),
           session.reservation?.knownReservationID == remote.reservationID {
            session.endReservation()
            return
        }
        Task.detached {
            await RemoteReservation.release(
                reservationID: remote.reservationID, projectID: remote.projectID, cli: AndroidCLI.shared, ledger: .shared
            )
        }
    }
}

/// A remote device reserved for a tab, from `devices.reserve` until it connects.
nonisolated struct RemoteClaim: Equatable, Sendable {
    var id = UUID()
    var owner: DeviceLeaseOwner
    var deviceTabID: UUID
    var deviceTabCreated: Bool
    /// `codename/api`.
    var model: String
    /// Nil when the catalog didn't name the model.
    var form: DeviceForm? = nil
    var projectID: String
    var ttl: TimeInterval
    var worktree: String?
    var branch: String?
}

/// The coordinator's changes to the registry, each limited to leases whose owner names `app`.
/// Those that return leases return the remote ones whose reservations must end with them.
nonisolated extension DeviceRegistry {
    private func isMine(_ owner: DeviceLeaseOwner, _ app: String) -> Bool { owner.app == app }

    mutating func forget(tabID: UUID, app: String) -> [DeviceLease] {
        let owner = DeviceLeaseOwner.tab(id: tabID, app: app)
        var ended: [DeviceLease] = []
        for (key, lease) in devices where isMine(lease.owner, app) {
            if lease.owner == owner {
                devices[key] = nil
                if lease.kind == .remote { ended.append(lease) }
            } else if lease.deviceTabID == tabID {
                if lease.kind == .remote {
                    devices[key] = nil
                } else {
                    devices[key]?.deviceTabID = nil
                    devices[key]?.deviceTabCreatedByClaim = false
                }
            }
        }
        // An `avd:` entry stays until it expires: its `plume` may still be booting, and dropping it
        // would let a second claimant boot the same AVD.
        for (key, entry) in pending where isMine(entry.owner, app) && !key.hasPrefix(Self.pendingAVDPrefix)
            && (entry.owner == owner || entry.deviceTabID == tabID) {
            pending[key] = nil
        }
        return ended
    }

    mutating func sweepAtLaunch(app: String, liveTabIDs: Set<UUID>) {
        func isLive(_ owner: DeviceLeaseOwner) -> Bool { owner.tabID.map(liveTabIDs.contains) ?? false }
        for (key, lease) in devices where isMine(lease.owner, app) {
            if lease.kind == .remote || !isLive(lease.owner) {
                devices[key] = nil
            } else if let deviceTab = lease.deviceTabID, !liveTabIDs.contains(deviceTab) {
                devices[key]?.deviceTabID = nil
                devices[key]?.deviceTabCreatedByClaim = false
            }
        }
        for (key, entry) in pending where isMine(entry.owner, app) && (key.hasPrefix(Self.pendingClaimPrefix) || !isLive(entry.owner)) {
            pending[key] = nil
        }
    }

    mutating func dropExpired(app: String, now: Date) -> [DeviceLease] {
        var ended: [DeviceLease] = []
        for (key, lease) in devices where isMine(lease.owner, app) && lease.expiresAt < now {
            devices[key] = nil
            if lease.kind == .remote { ended.append(lease) }
        }
        for (key, entry) in pending where isMine(entry.owner, app) && entry.expiresAt < now {
            pending[key] = nil
        }
        return ended
    }

    mutating func recordClaim(_ claim: RemoteClaim, now: Date) {
        pending[Self.pendingKey(claim: claim.id)] = PendingDevice(
            owner: claim.owner,
            kind: .remote,
            model: claim.model,
            deviceTabID: claim.deviceTabID,
            startedAt: now,
            expiresAt: now.addingTimeInterval(DevicePool.pendingBootTTL)
        )
    }

    /// Leases the device even when the claim's pending entry was reaped meanwhile: the
    /// reservation exists either way, and a claimant that gave up finds it on its next claim.
    mutating func attach(_ claim: RemoteClaim, reservationID: String, serial: String, now: Date) {
        pending[Self.pendingKey(claim: claim.id)] = nil
        devices[Self.remoteKey(reservationID: reservationID)] = DeviceLease(
            kind: .remote,
            serial: serial,
            form: claim.form,
            model: claim.model,
            owner: claim.owner,
            worktree: claim.worktree,
            branch: claim.branch,
            claimedAt: now,
            expiresAt: now.addingTimeInterval(claim.ttl),
            deviceTabID: claim.deviceTabID,
            deviceTabCreatedByClaim: claim.deviceTabCreated,
            remote: .init(reservationID: reservationID, projectID: claim.projectID, claimID: claim.id)
        )
    }

    mutating func reattach(reservationID: String, serial: String, app: String) {
        let key = Self.remoteKey(reservationID: reservationID)
        guard let lease = devices[key], isMine(lease.owner, app), lease.serial != serial else { return }
        devices[key]?.serial = serial
    }

    mutating func failClaim(_ claimID: UUID, message: String) {
        pending[Self.pendingKey(claim: claimID)]?.error = message
    }

    mutating func dropRemoteLease(reservationID: String, app: String) {
        let key = Self.remoteKey(reservationID: reservationID)
        if let lease = devices[key], isMine(lease.owner, app) { devices[key] = nil }
    }

    mutating func takeLease(_ key: String, app: String) -> DeviceLease? {
        guard let lease = devices[key], isMine(lease.owner, app) else { return nil }
        devices[key] = nil
        return lease
    }

    /// For quit, which ends every reservation. True when anything went.
    mutating func dropRemote(app: String) -> Bool {
        let before = self
        devices = devices.filter { !(isMine($0.value.owner, app) && $0.value.kind == .remote) }
        pending = pending.filter { !(isMine($0.value.owner, app) && $0.key.hasPrefix(Self.pendingClaimPrefix)) }
        return self != before
    }
}
