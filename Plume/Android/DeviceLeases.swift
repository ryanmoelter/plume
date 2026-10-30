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
    }

    let store: DeviceRegistryStore
    let leases: DeviceLeaseStore
    var effects: Effects
    /// The socket this app serves. Nil until `start`, and then every call is a no-op.
    private(set) var appSocket: String?
    private let now: @Sendable () -> Date
    private let queue = DispatchQueue(label: "com.ryanmoelter.Plume.device-leases", qos: .utility)
    private var watcher: FileWatcher?
    private var reapTask: Task<Void, Never>?

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
        let watcher = FileWatcher(url: URL(fileURLWithPath: store.registryFile), createsFile: false) { [weak self] in
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
                registry = try store.load { EmulatorLog.error("device leases: \($0)") }
            } catch {
                EmulatorLog.error("device leases: \(error)")
                return
            }
            self.onMain { coordinator in coordinator.leases.publish(registry, app: app) }
        }
    }

    /// The tab's own leases go, and a remote one ends its reservation. A lease whose device tab
    /// this was keeps going without it, unless it is remote: the reservation closed with the tab.
    func tabForgotten(_ tabID: UUID) {
        mutate { registry, app, _ in registry.forget(tabID: tabID, app: app) }
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
                var registry = try store.load { _ in }
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

    /// Runs `change` under the registry lock off the main actor, saves when it changed, then
    /// publishes and ends the reservations of the remote leases it returned.
    private func mutate(_ change: @escaping @Sendable (inout DeviceRegistry, _ app: String, _ now: Date) -> [DeviceLease]) {
        guard let app = appSocket else { return }
        let (store, now) = (store, now)
        queue.async { [self] in
            let outcome: (registry: DeviceRegistry, ended: [DeviceLease])
            do {
                outcome = try store.withLock {
                    var registry = try store.load { EmulatorLog.error("device leases: \($0)") }
                    let before = registry
                    let ended = change(&registry, app, now())
                    if registry != before { try store.save(registry) }
                    return (registry, ended)
                }
            } catch {
                EmulatorLog.error("device leases: \(error)")
                return
            }
            self.onMain { coordinator in
                coordinator.leases.publish(outcome.registry, app: app)
                for lease in outcome.ended { coordinator.release(lease) }
            }
        }
    }

    private func release(_ lease: DeviceLease) {
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

/// The coordinator's changes to the registry, each limited to leases whose owner names `app`.
/// Each returns the remote leases whose reservations must end with them.
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
        for (key, entry) in pending where isMine(entry.owner, app) && (entry.owner == owner || entry.deviceTabID == tabID) {
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

    /// For quit, which ends every reservation. True when anything went.
    mutating func dropRemote(app: String) -> Bool {
        let before = self
        devices = devices.filter { !(isMine($0.value.owner, app) && $0.value.kind == .remote) }
        pending = pending.filter { !(isMine($0.value.owner, app) && $0.key.hasPrefix(Self.pendingClaimPrefix)) }
        return self != before
    }
}
