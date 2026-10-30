import Foundation

nonisolated struct DeviceOwnerInfo: Equatable, Sendable {
    var worktree: String
    var branch: String?
}

/// Everything the pool asks of the machine, so tests can fake adb, the emulator and git.
nonisolated protocol DeviceEnvironment: AnyObject {
    func now() -> Date
    /// Every device adb lists, emulators included. Throws when adb can't be run.
    func adbDevices() throws -> [PhysicalDevice]
    /// The AVD behind each running emulator's serial, booting ones included.
    func emulatorAVDs() -> [String: String]
    /// Best effort: an AVD's `config.ini` first, else the screen adb reports.
    func form(of device: PhysicalDevice, avd: String?) -> DeviceForm?
    /// The AVDs that could be booted, in preference order. Throws when the emulator isn't installed.
    func avds() throws -> [String]
    func avdForm(_ avd: String) -> DeviceForm?
    /// Boots `avd` and waits until it finishes booting. Returns its serial.
    func boot(avd: String, log: (String) -> Void) throws -> String
    /// The enclosing git worktree, or nil outside one.
    func ownerInfo() -> DeviceOwnerInfo?
    func sleep(_ seconds: TimeInterval)
}

nonisolated struct DeviceClaimant: Equatable, Sendable {
    var owner: DeviceLeaseOwner
    var worktree: String?
    var branch: String?
}

nonisolated enum DeviceKindFilter: String, CaseIterable, Sendable {
    case emulator
    case physical
    case any

    func admits(isEmulator: Bool) -> Bool {
        switch self {
        case .emulator: isEmulator
        case .physical: !isEmulator
        case .any: true
        }
    }
}

nonisolated enum DevicePoolError: Error, Equatable {
    /// `key` is leased by another owner.
    case conflict(key: String, lease: DeviceLease)
    /// The device's AVD is booting for another claimant, who hasn't leased it yet.
    case booting(key: String, pending: PendingDevice)
    /// Nothing free matches. `leaseLines` describes what holds the devices.
    case exhausted(leaseLines: [String])
}

nonisolated struct DeviceListingRow: Encodable, Equatable {
    var serial: String?
    var kind: DeviceKind
    var avd: String?
    var form: DeviceForm?
    /// adb's word for the device (`device`, `offline`, `unauthorized`), `booting` for a pending
    /// boot, `reserving` for a pending remote claim, or `remote` for a remote lease adb doesn't
    /// list.
    var state: String
    var lease: DeviceLease?
    var pending: PendingDevice?
}

/// The lease operations behind `plume devices`. Each takes the registry lock, reaps, mutates and
/// saves. `acquire` releases the lock around an emulator boot; its pending entry is what keeps a
/// second claimant from booting the same AVD meanwhile.
nonisolated final class DevicePool {
    static let defaultTTL: TimeInterval = 3600
    /// A cold boot can run past five minutes, and an expired pending entry invites a double boot.
    static let pendingBootTTL: TimeInterval = 900

    let store: DeviceRegistryStore
    let environment: any DeviceEnvironment
    let warn: (String) -> Void
    let log: (String) -> Void

    init(
        store: DeviceRegistryStore,
        environment: any DeviceEnvironment,
        warn: @escaping (String) -> Void,
        log: @escaping (String) -> Void
    ) {
        self.store = store
        self.environment = environment
        self.warn = warn
        self.log = log
    }

    private struct Snapshot {
        var registry: DeviceRegistry
        var live: [PhysicalDevice]
        var emulatorAVDs: [String: String]
        var reaped: [String]
    }

    private func loadReaped(warnReaped: Bool = true) throws -> Snapshot {
        var registry = try store.load(warn: warn)
        let live = try environment.adbDevices()
        let emulatorAVDs = environment.emulatorAVDs()
        let reaped = registry.reap(liveSerials: Set(live.map(\.serial)), emulatorAVDs: emulatorAVDs, now: environment.now())
        if warnReaped { reaped.forEach(warn) }
        return Snapshot(registry: registry, live: live, emulatorAVDs: emulatorAVDs, reaped: reaped)
    }

    private func saveIfReaped(_ snapshot: Snapshot) throws {
        if !snapshot.reaped.isEmpty { try store.save(snapshot.registry) }
    }

    private func newLease(
        for device: PhysicalDevice, avd: String?, form: DeviceForm?, claimant: DeviceClaimant, ttl: TimeInterval, now: Date
    ) -> DeviceLease {
        let isEmulator = Self.isEmulator(device.serial)
        return DeviceLease(
            kind: isEmulator ? .emulator : .physical,
            serial: device.serial,
            avd: avd,
            form: form,
            model: device.model,
            owner: claimant.owner,
            worktree: claimant.worktree,
            branch: claimant.branch,
            claimedAt: now,
            expiresAt: now.addingTimeInterval(ttl)
        )
    }

    static func isEmulator(_ serial: String) -> Bool { serial.hasPrefix("emulator-") }

    /// Device Streaming attaches its devices as `localhost:<port>`. Only `--kind=remote` leases
    /// one, through the app that holds its reservation.
    static func isRemoteSerial(_ serial: String) -> Bool { serial.hasPrefix("localhost:") }

    /// The forms of the devices a claim might lease, read before the lock is taken: a physical
    /// device's costs `adb shell` round trips, which must not hold every other claimant up.
    private func formsOutsideLock(of serials: (PhysicalDevice) -> Bool) -> [String: DeviceForm] {
        guard let devices = try? environment.adbDevices() else { return [:] }
        let leased = (try? store.load { _ in })?.devices ?? [:]
        let avds = environment.emulatorAVDs()
        var forms: [String: DeviceForm] = [:]
        for device in devices where device.isReady && !Self.isRemoteSerial(device.serial) && serials(device) {
            if let form = leased[device.serial]?.form ?? environment.form(of: device, avd: avds[device.serial]) {
                forms[device.serial] = form
            }
        }
        return forms
    }

    /// Claims one connected device. Claiming your own lease again renews it. The key is the
    /// lease's registry key, which for a remote device isn't its serial.
    func claimSerial(_ serial: String, claimant: DeviceClaimant, ttl: TimeInterval) throws -> (key: String, lease: DeviceLease, reused: Bool) {
        let forms = formsOutsideLock { $0.serial == serial }
        return try store.withLock {
            let now = environment.now()
            var snapshot = try loadReaped()
            guard let device = snapshot.live.first(where: { $0.serial == serial }) else {
                try saveIfReaped(snapshot)
                throw CLIFailure("\(serial) is not a connected device (not in `adb devices`)")
            }
            let key = snapshot.registry.leaseKey(for: serial) ?? serial
            if var held = snapshot.registry.devices[key] {
                guard held.owner == claimant.owner else { throw DevicePoolError.conflict(key: key, lease: held) }
                held.expiresAt = now.addingTimeInterval(ttl)
                snapshot.registry.devices[key] = held
                try store.save(snapshot.registry)
                return (key, held, true)
            }
            if Self.isRemoteSerial(serial) {
                try saveIfReaped(snapshot)
                throw CLIFailure("\(serial) is a remote device; reserve one with --kind=remote")
            }
            let avd = snapshot.emulatorAVDs[serial]
            if let avd, let booting = snapshot.registry.pending[DeviceRegistry.pendingKey(avd: avd)], booting.owner != claimant.owner {
                try saveIfReaped(snapshot)
                throw DevicePoolError.booting(key: DeviceRegistry.pendingKey(avd: avd), pending: booting)
            }
            let lease = newLease(for: device, avd: avd, form: forms[serial], claimant: claimant, ttl: ttl, now: now)
            snapshot.registry.devices[serial] = lease
            try store.save(snapshot.registry)
            return (serial, lease, false)
        }
    }

    private enum AcquirePlan {
        case leased(serial: String, lease: DeviceLease, reused: Bool)
        case boot(avd: String)
    }

    /// Gets a free device matching the filters, or boots one, and claims it. A booted device is
    /// preferred, and is the only way to a physical one; otherwise an AVD that is neither running
    /// nor already booting for someone is started.
    func acquire(
        claimant: DeviceClaimant,
        ttl: TimeInterval,
        kind: DeviceKindFilter,
        form: DeviceForm?
    ) throws -> (serial: String, lease: DeviceLease, reused: Bool) {
        let forms = formsOutsideLock { kind.admits(isEmulator: Self.isEmulator($0.serial)) }
        let plan: AcquirePlan = try store.withLock {
            let now = environment.now()
            var snapshot = try loadReaped()
            let runningAVDs = Set(snapshot.emulatorAVDs.values)
            let pendingAVDs = snapshot.registry.pendingAVDs
            for device in snapshot.live where device.isReady && !Self.isRemoteSerial(device.serial) {
                let isEmulator = Self.isEmulator(device.serial)
                guard kind.admits(isEmulator: isEmulator) else { continue }
                let held = snapshot.registry.devices[device.serial]
                if let held, held.owner != claimant.owner { continue }
                let avd = snapshot.emulatorAVDs[device.serial]
                // Booted for a claimant who hasn't leased it yet.
                if let avd, held == nil, pendingAVDs.contains(avd) { continue }
                // A device that appeared after the forms were read has none, and fails a --form filter.
                let deviceForm = held?.form ?? forms[device.serial]
                if let form, deviceForm != form { continue }

                var lease = held ?? newLease(for: device, avd: avd, form: deviceForm, claimant: claimant, ttl: ttl, now: now)
                lease.expiresAt = now.addingTimeInterval(ttl)
                snapshot.registry.devices[device.serial] = lease
                try store.save(snapshot.registry)
                return .leased(serial: device.serial, lease: lease, reused: held != nil)
            }

            guard kind != .physical else {
                try saveIfReaped(snapshot)
                throw DevicePoolError.exhausted(leaseLines: Self.leaseLines(snapshot.registry, now: now))
            }
            let avds = try environment.avds()
            guard !avds.isEmpty else {
                try saveIfReaped(snapshot)
                throw CLIFailure("no AVDs to boot; create one in Android Studio's Device Manager first")
            }
            let target = avds.first { avd in
                !runningAVDs.contains(avd) && !pendingAVDs.contains(avd) && (form == nil || environment.avdForm(avd) == form)
            }
            guard let target else {
                try saveIfReaped(snapshot)
                throw DevicePoolError.exhausted(leaseLines: Self.leaseLines(snapshot.registry, now: now))
            }
            snapshot.registry.pending[DeviceRegistry.pendingKey(avd: target)] = PendingDevice(
                owner: claimant.owner,
                kind: .emulator,
                avd: target,
                startedAt: now,
                expiresAt: now.addingTimeInterval(Self.pendingBootTTL)
            )
            try store.save(snapshot.registry)
            return .boot(avd: target)
        }

        switch plan {
        case .leased(let serial, let lease, let reused):
            return (serial, lease, reused)
        case .boot(let avd):
            let serial: String
            do {
                serial = try environment.boot(avd: avd, log: log)
            } catch {
                dropPending(avd: avd)
                throw error
            }
            return try store.withLock {
                let now = environment.now()
                var snapshot = try loadReaped()
                snapshot.registry.pending[DeviceRegistry.pendingKey(avd: avd)] = nil
                if let held = snapshot.registry.devices[serial], held.owner != claimant.owner {
                    try store.save(snapshot.registry)
                    throw DevicePoolError.conflict(key: serial, lease: held)
                }
                let lease = DeviceLease(
                    kind: .emulator,
                    serial: serial,
                    avd: avd,
                    form: environment.avdForm(avd),
                    owner: claimant.owner,
                    worktree: claimant.worktree,
                    branch: claimant.branch,
                    claimedAt: now,
                    expiresAt: now.addingTimeInterval(ttl)
                )
                snapshot.registry.devices[serial] = lease
                try store.save(snapshot.registry)
                return (serial, lease, false)
            }
        }
    }

    /// Best effort: if this fails, the pending entry's TTL reaps it.
    private func dropPending(avd: String) {
        try? store.withLock {
            var registry = try store.load(warn: warn)
            if registry.pending.removeValue(forKey: DeviceRegistry.pendingKey(avd: avd)) != nil {
                try store.save(registry)
            }
        }
    }

    /// The lease removed, or nil when `key` wasn't leased. Another owner's lease needs `force`.
    func release(_ key: String, owner: DeviceLeaseOwner, force: Bool) throws -> DeviceLease? {
        try store.withLock {
            var snapshot = try loadReaped()
            guard let held = snapshot.registry.devices[key] else {
                try saveIfReaped(snapshot)
                return nil
            }
            guard held.owner == owner || force else { throw DevicePoolError.conflict(key: key, lease: held) }
            snapshot.registry.devices[key] = nil
            try store.save(snapshot.registry)
            return held
        }
    }

    /// Releases every local lease `owner` holds, and returns them by key. A remote lease is left for
    /// the app holding its reservation to release.
    func releaseMine(owner: DeviceLeaseOwner) throws -> [(key: String, lease: DeviceLease)] {
        try store.withLock {
            var snapshot = try loadReaped()
            let mine = snapshot.registry.devices
                .filter { $0.value.owner == owner && $0.value.kind != .remote }
                .sorted { $0.key < $1.key }
            for (key, _) in mine { snapshot.registry.devices[key] = nil }
            if mine.isEmpty { try saveIfReaped(snapshot) } else { try store.save(snapshot.registry) }
            return mine.map { (key: $0.key, lease: $0.value) }
        }
    }

    /// The lease at `key`, after reaping. Another owner's lease throws unless `force`.
    func lease(_ key: String, owner: DeviceLeaseOwner, force: Bool) throws -> DeviceLease? {
        try store.withLock {
            let snapshot = try loadReaped()
            try saveIfReaped(snapshot)
            guard let held = snapshot.registry.devices[key] else { return nil }
            guard held.owner == owner || force else { throw DevicePoolError.conflict(key: key, lease: held) }
            return held
        }
    }

    func remoteLeases(ownedBy owner: DeviceLeaseOwner) throws -> [(key: String, lease: DeviceLease)] {
        try store.load(warn: warn).devices
            .filter { $0.value.owner == owner && $0.value.kind == .remote }
            .sorted { $0.key < $1.key }
            .map { (key: $0.key, lease: $0.value) }
    }

    /// The registry key a command names: a key itself, or a remote lease's current adb serial.
    func leaseKey(for serial: String) throws -> String {
        try store.load(warn: warn).leaseKey(for: serial) ?? serial
    }

    enum RemoteClaimState: Equatable {
        /// Renewed for the new TTL.
        case held(key: String, lease: DeviceLease)
        /// A device is still being reserved for this owner.
        case waiting(claimID: UUID)
        case none
    }

    /// What a remote claim finds already in place for `owner`. A pending claim that failed is
    /// dropped, so the next one starts afresh.
    func remoteClaimState(owner: DeviceLeaseOwner, ttl: TimeInterval) throws -> RemoteClaimState {
        try store.withLock {
            var snapshot = try loadReaped()
            if let (key, held) = snapshot.registry.devices.sorted(by: { $0.key < $1.key })
                .first(where: { $0.value.owner == owner && $0.value.kind == .remote }) {
                var lease = held
                lease.expiresAt = environment.now().addingTimeInterval(ttl)
                snapshot.registry.devices[key] = lease
                try store.save(snapshot.registry)
                return .held(key: key, lease: lease)
            }
            var state = RemoteClaimState.none
            var changed = !snapshot.reaped.isEmpty
            for (key, entry) in snapshot.registry.pending.sorted(by: { $0.key < $1.key })
            where entry.owner == owner && key.hasPrefix(DeviceRegistry.pendingClaimPrefix) {
                if entry.error != nil {
                    snapshot.registry.pending[key] = nil
                    changed = true
                } else if state == .none, let claimID = UUID(uuidString: String(key.dropFirst(DeviceRegistry.pendingClaimPrefix.count))) {
                    state = .waiting(claimID: claimID)
                }
            }
            if changed { try store.save(snapshot.registry) }
            return state
        }
    }

    func renew(_ key: String, owner: DeviceLeaseOwner, ttl: TimeInterval) throws -> DeviceLease {
        try store.withLock {
            var snapshot = try loadReaped()
            guard var held = snapshot.registry.devices[key] else {
                try saveIfReaped(snapshot)
                throw CLIFailure("\(key) is not leased")
            }
            guard held.owner == owner else { throw DevicePoolError.conflict(key: key, lease: held) }
            held.expiresAt = environment.now().addingTimeInterval(ttl)
            snapshot.registry.devices[key] = held
            try store.save(snapshot.registry)
            return held
        }
    }

    /// Records which build is on the device. False when it has no lease to annotate.
    func noteInstalled(_ key: String, branch: String, worktree: String?) throws -> Bool {
        try store.withLock {
            var snapshot = try loadReaped()
            guard snapshot.registry.devices[key] != nil else {
                try saveIfReaped(snapshot)
                return false
            }
            snapshot.registry.devices[key]?.installed = .init(branch: branch, worktree: worktree, at: environment.now())
            try store.save(snapshot.registry)
            return true
        }
    }

    /// Notes the tab showing a lease's device. A tab an earlier claim created stays marked so.
    func recordDeviceTab(_ key: String, owner: DeviceLeaseOwner, tabID: UUID, created: Bool) throws {
        try store.withLock {
            var registry = try store.load(warn: warn)
            guard var lease = registry.devices[key], lease.owner == owner else { return }
            lease.deviceTabCreatedByClaim = created || (lease.deviceTabID == tabID && lease.deviceTabCreatedByClaim)
            lease.deviceTabID = tabID
            registry.devices[key] = lease
            try store.save(registry)
        }
    }

    /// Reaps now, and returns what went.
    func prune() throws -> [String] {
        try store.withLock {
            let snapshot = try loadReaped(warnReaped: false)
            try saveIfReaped(snapshot)
            return snapshot.reaped
        }
    }

    /// Live devices merged with their leases, then remote leases and pending entries.
    func listing() throws -> [DeviceListingRow] {
        let snapshot = try store.withLock {
            let snapshot = try loadReaped()
            try saveIfReaped(snapshot)
            return snapshot
        }
        let registry = snapshot.registry
        let remoteBySerial = registry.remoteLeasesBySerial
        var rows: [DeviceListingRow] = snapshot.live.map { device in
            let remote = remoteBySerial[device.serial]?.lease
            let lease = registry.devices[device.serial] ?? remote
            let avd = snapshot.emulatorAVDs[device.serial]
            return DeviceListingRow(
                serial: device.serial,
                kind: remote != nil || Self.isRemoteSerial(device.serial) ? .remote : Self.isEmulator(device.serial) ? .emulator : .physical,
                avd: avd,
                form: lease?.form ?? environment.form(of: device, avd: avd),
                state: Self.adbWord(device.state),
                lease: lease
            )
        }
        let live = Set(snapshot.live.map(\.serial))
        for (key, lease) in registry.devices.sorted(by: { $0.key < $1.key }) where !live.contains(lease.serial ?? key) {
            rows.append(DeviceListingRow(serial: lease.serial ?? key, kind: lease.kind, avd: lease.avd, form: lease.form, state: "remote", lease: lease))
        }
        for (_, pending) in registry.pending.sorted(by: { $0.key < $1.key }) {
            let state = pending.kind == .remote ? "reserving" : "booting"
            rows.append(DeviceListingRow(serial: nil, kind: pending.kind, avd: pending.avd, form: nil, state: state, pending: pending))
        }
        return rows
    }

    static func adbWord(_ state: PhysicalDevice.State) -> String {
        switch state {
        case .ready: "device"
        case .unauthorized: "unauthorized"
        case .offline: "offline"
        case .other(let word): word
        }
    }

    static func leaseLines(_ registry: DeviceRegistry, now: Date) -> [String] {
        var lines: [String] = []
        for (key, lease) in registry.devices.sorted(by: { $0.key < $1.key }) {
            lines.append("  \(key)  \(describe(lease))  held by \(holder(lease)), expires in \(relativeTime(lease.expiresAt.timeIntervalSince(now)))")
        }
        for (key, pending) in registry.pending.sorted(by: { $0.key < $1.key }) {
            let what = pending.avd ?? pending.model ?? key
            let state = pending.kind == .remote ? "(reserving)" : "(booting)"
            lines.append("  \(state)  \(what)  held by \(pending.owner), started \(relativeTime(now.timeIntervalSince(pending.startedAt))) ago")
        }
        return lines
    }

    static func describe(_ lease: DeviceLease) -> String {
        var what = lease.avd ?? lease.model ?? lease.kind.rawValue
        if let form = lease.form { what += " [\(form.rawValue)]" }
        return what
    }

    static func holder(_ lease: DeviceLease) -> String {
        lease.branch.map { "\(lease.owner) (branch \($0))" } ?? lease.owner.description
    }

    static func relativeTime(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        if seconds >= 3600 { return "\(seconds / 3600)h" + String(format: "%02dm", seconds % 3600 / 60) }
        if seconds >= 60 { return "\(seconds / 60)m" }
        return "\(seconds)s"
    }
}
