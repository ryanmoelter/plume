import Foundation
import Observation
import Virtualization

/// The app's pool of macOS VMs: slots `vm:1` and `vm:2`, each booting clone `plume-<os>-<n>` of
/// `plume-base-<os>`. Views never create or destroy VMs; they read a slot and show its `displays`
/// adaptor. Leases live in memory only, since the VMs die with the app. `docs/vm-testing.md` is the
/// reference.
@MainActor
@Observable
final class VMManager {
    static let shared = VMManager(backend: LiveVMBackend())

    static let defaultTTL: TimeInterval = 3600
    static let bootDeadline: Duration = .seconds(240)
    static let reapInterval: Duration = .seconds(60)
    /// How long a quit lets guests shut down before it forces them.
    static let terminationGracePeriod: TimeInterval = 8
    /// When a quit stops waiting even on a forced stop that hasn't finished.
    static let terminationDeadline: TimeInterval = 30

    /// A VM tab hands its VM to the view through `VZVirtualMachineViewAdaptor`, new in macOS 27.
    nonisolated static var isSupported: Bool {
        if #available(macOS 27.0, *) { true } else { false }
    }

    nonisolated static let unsupportedMessage = "VMs need macOS 27"

    struct Lease: Equatable {
        var owner: DeviceLeaseOwner
        var worktree: String?
        var branch: String?
        var claimedAt: Date
        var expiresAt: Date
        var installed: DeviceLease.Installed?
        var token = UUID()
    }

    struct Slot: Equatable, Identifiable {
        let number: Int
        var state: VMSlotState = .idle
        var lease: Lease?
        var ip: String?
        var error: String?
        var poolFull = false
        /// The last stop left the VM running even when forced, so the slot still holds its clone
        /// lock. Whatever runs on the slot next stops it again first.
        var stillRunning = false
        /// Bumped by every boot, stop and reset, so a completion from an earlier one is ignored.
        var generation: UInt64 = 0

        var id: Int { number }
        var key: String { VMPaths.key(number) }
    }

    enum Failure: LocalizedError, Equatable {
        case poolFull
        case missingBase(String)
        case worktreeMismatch(key: String, held: String?, wanted: String?)
        case unknownKey(String)
        case notLeased(String)
        case notOwner(key: String, holder: String)
        case busy(key: String, state: VMSlotState)
        case heldElsewhere(String)
        case slotTaken(String)
        case stillRunning(String)
        case unsupported

        var errorDescription: String? {
            switch self {
            case .poolFull:
                "VM pool full (\(VMPaths.slotCount) of \(VMPaths.slotCount) slots in use)"
            case .missingBase(let base):
                "no base image \(base); build it with scripts/vm/make-base-image.sh"
            case .worktreeMismatch(let key, let held, let wanted):
                "you already hold \(key), sharing \(held ?? "no worktree"); shares are fixed at boot, "
                    + "so release it before claiming one for \(wanted ?? "no worktree")"
            case .unknownKey(let key):
                "no VM slot \(key); the slots are " + (1...VMPaths.slotCount).map(VMPaths.key).joined(separator: ", ")
            case .notLeased(let key):
                "\(key) is not leased"
            case .notOwner(let key, let holder):
                "\(key) is leased by another owner, \(holder)"
            case .busy(let key, let state):
                "\(key) is \(state.rawValue); release it first"
            case .heldElsewhere(let key):
                "another Plume is running \(key)'s clone"
            case .slotTaken(let key):
                "\(key) is in use"
            case .stillRunning(let key):
                VMManager.stillRunningMessage(key)
            case .unsupported:
                VMManager.unsupportedMessage
            }
        }
    }

    private(set) var slots: [Slot]
    /// What a `VZVirtualMachineView` shows, by slot, while the VM runs. `VMDisplay.attach(to:)`
    /// hands the VM to a view on the main actor; the VM's own calls stay on its queue.
    private(set) var displays: [Int: VMDisplay] = [:]

    @ObservationIgnored private let backend: any VMBackend
    @ObservationIgnored var now: () -> Date = Date.init
    /// Whether a tab is a VM or device tab in a task that isn't archived. A lease such a tab owns renews
    /// itself for as long as the tab is there.
    @ObservationIgnored var isLiveVMTab: (UUID) -> Bool = { _ in false }
    @ObservationIgnored private var bootTasks: [Int: Task<Void, Never>] = [:]
    @ObservationIgnored private var deadlineTasks: [Int: Task<Void, Never>] = [:]
    /// The slot's last stop, until it finishes.
    @ObservationIgnored private var stopTasks: [Int: Task<Void, Never>] = [:]
    @ObservationIgnored private var stopIDs: [Int: UUID] = [:]
    @ObservationIgnored private var reapTask: Task<Void, Never>?
    /// As of the last claim or `refreshHeldElsewhere`, so reporting never reads lock files on the
    /// main actor.
    @ObservationIgnored private var heldElsewhere: Set<Int> = []

    init(backend: any VMBackend) {
        self.backend = backend
        slots = (1...VMPaths.slotCount).map { Slot(number: $0) }
        backend.guestDidStop = { [weak self] slot, generation, reason in
            self?.guestStopped(slot, generation: generation, reason: reason)
        }
    }

    func start() {
        guard reapTask == nil else { return }
        reapTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.reapInterval)
                self?.reapExpired()
            }
        }
    }

    func slot(_ number: Int) -> Slot? { slots.first { $0.number == number } }

    /// Slots that may still have a VM, which a quit has to stop: a failed slot's VM is still
    /// stopping until its stop finishes, or running if that stop failed.
    var runningCount: Int {
        slots.filter { slot in
            slot.stillRunning
                || (slot.state != .idle && slot.state != .resetting && (slot.state != .failed || stopTasks[slot.number] != nil))
        }.count
    }

    nonisolated static func stillRunningMessage(_ key: String) -> String {
        "\(key) didn't stop when forced; its clone stays locked until a retry stops it or Plume quits"
    }

    // MARK: Leases

    /// Leases a slot and boots it in the background, answering at once. A claim by an owner that
    /// already holds a slot renews it, and boots it again if its boot failed. `preferred` asks for
    /// one slot, as a VM tab's picker does, and fails rather than take another; an owner that
    /// already holds a slot still gets its own. The host checks run off the main actor, and
    /// everything after them reads the slots afresh.
    func claim(
        owner: DeviceLeaseOwner,
        worktree requestedWorktree: String?,
        branch: String?,
        ttl: TimeInterval? = nil,
        preferred: Int? = nil
    ) async throws -> (slot: Int, reused: Bool) {
        guard Self.isSupported else { throw Failure.unsupported }
        let ttl = ttl ?? Self.defaultTTL
        let worktree = await Self.resolved(requestedWorktree)
        let baseExists = await backend.baseImageExists()
        let elsewhere = await backend.clonesHeldElsewhere()
        heldElsewhere = elsewhere
        if let held = slots.first(where: { $0.lease?.owner == owner }) {
            let lease = held.lease!
            if let worktree, worktree != lease.worktree {
                throw Failure.worktreeMismatch(key: held.key, held: lease.worktree, wanted: worktree)
            }
            update(held.number) { $0.lease?.expiresAt = now().addingTimeInterval(ttl) }
            if held.state == .failed { boot(held.number) }
            return (held.number, true)
        }
        guard baseExists else { throw Failure.missingBase(VMPaths.baseName(os: backend.hostOSMajor)) }
        let isFree = { (slot: Slot) in
            slot.lease == nil && (slot.state == .idle || slot.state == .failed) && !elsewhere.contains(slot.number)
        }
        let free: Slot
        if let preferred {
            guard let wanted = slot(preferred) else { throw Failure.unknownKey(VMPaths.key(preferred)) }
            guard isFree(wanted) else { throw Failure.slotTaken(wanted.key) }
            free = wanted
        } else {
            guard let first = slots.first(where: isFree) else { throw Failure.poolFull }
            free = first
        }
        let claimedAt = now()
        update(free.number) {
            $0.lease = Lease(owner: owner, worktree: worktree, branch: branch, claimedAt: claimedAt, expiresAt: claimedAt.addingTimeInterval(ttl))
        }
        boot(free.number)
        return (free.number, false)
    }

    func renew(_ key: String, owner: DeviceLeaseOwner, ttl: TimeInterval) throws -> Lease {
        let number = try leasedSlot(key, owner: owner, force: false)
        update(number) { $0.lease?.expiresAt = now().addingTimeInterval(ttl) }
        return slot(number)!.lease!
    }

    /// Stops the VM and keeps its clone, so the next boot is warm. A slot with no lease whose VM
    /// didn't stop is stopped again, whoever asks.
    func release(_ key: String, owner: DeviceLeaseOwner, force: Bool) throws {
        if let number = VMPaths.slot(fromKey: key), let current = slot(number),
           current.lease == nil, current.stillRunning, current.state == .failed {
            return stopSlot(number)
        }
        stopSlot(try leasedSlot(key, owner: owner, force: force))
    }

    func noteInstalled(_ key: String, branch: String, worktree: String?) throws {
        guard let number = VMPaths.slot(fromKey: key) else { throw Failure.unknownKey(key) }
        guard slot(number)?.lease != nil else { throw Failure.notLeased(key) }
        update(number) { $0.lease?.installed = DeviceLease.Installed(branch: branch, worktree: worktree, at: now()) }
    }

    /// Deletes a free slot's clone, so its next boot starts from the base again. A stop still
    /// running finishes first, and a VM that didn't stop is stopped again before anything is
    /// deleted.
    func reset(_ key: String) async throws {
        guard let number = VMPaths.slot(fromKey: key) else { throw Failure.unknownKey(key) }
        try checkResettable(number)
        if let pending = stopTasks[number] { await pending.value }
        if slot(number)!.stillRunning {
            try checkResettable(number)
            stopBackend(number, ip: nil, finalState: nil)
            await stopTasks[number]?.value
            guard !slot(number)!.stillRunning else { throw Failure.stillRunning(key) }
        }
        let elsewhere = await backend.clonesHeldElsewhere()
        heldElsewhere = elsewhere
        try checkResettable(number)
        guard !elsewhere.contains(number) else { throw Failure.heldElsewhere(key) }
        update(number) {
            $0.generation += 1
            $0.state = .resetting
            $0.error = nil
            $0.poolFull = false
        }
        let generation = slot(number)!.generation
        defer {
            if isCurrent(number, generation) { update(number) { $0.state = .idle } }
        }
        try await backend.deleteClone(slot: number)
    }

    private func checkResettable(_ number: Int) throws {
        let current = slot(number)!
        guard current.lease == nil, current.state == .idle || current.state == .failed else {
            throw Failure.busy(key: current.key, state: current.state)
        }
    }

    func tabForgotten(_ tabID: UUID) {
        for slot in slots where slot.lease?.owner.tabID == tabID {
            stopSlot(slot.number)
        }
    }

    func reapExpired() {
        let now = now()
        for slot in slots {
            guard let lease = slot.lease else { continue }
            if let tabID = lease.owner.tabID, isLiveVMTab(tabID) {
                update(slot.number) { $0.lease?.expiresAt = now.addingTimeInterval(Self.defaultTTL) }
            } else if lease.expiresAt <= now {
                stopSlot(slot.number)
            }
        }
    }

    private func leasedSlot(_ key: String, owner: DeviceLeaseOwner, force: Bool) throws -> Int {
        guard let number = VMPaths.slot(fromKey: key) else { throw Failure.unknownKey(key) }
        guard let lease = slot(number)?.lease else { throw Failure.notLeased(key) }
        guard force || lease.owner == owner else { throw Failure.notOwner(key: key, holder: lease.owner.description) }
        return number
    }

    // MARK: Boot

    private func boot(_ number: Int) {
        bootTasks[number]?.cancel()
        deadlineTasks[number]?.cancel()
        if slot(number)!.stillRunning { stopBackend(number, ip: nil, finalState: nil) }
        update(number) {
            $0.generation += 1
            $0.state = .reserved
            $0.error = nil
            $0.poolFull = false
            $0.ip = nil
        }
        let generation = slot(number)!.generation
        let pendingStop = stopTasks[number]
        bootTasks[number] = Task { [weak self] in
            await pendingStop?.value
            await self?.runBoot(number, generation: generation)
        }
        deadlineTasks[number] = Task { [weak self] in
            try? await Task.sleep(for: Self.bootDeadline)
            guard !Task.isCancelled, let self, isCurrent(number, generation), slot(number)?.state != .ready else { return }
            bootTasks[number]?.cancel()
            fail(number, generation: generation, message: "\(VMPaths.key(number)) wasn't ready within \(Int(Self.bootDeadline.components.seconds / 60)) minutes")
        }
    }

    private func runBoot(_ number: Int, generation: UInt64) async {
        guard isCurrent(number, generation) else { return }
        if slot(number)!.stillRunning {
            return fail(number, generation: generation, message: Self.stillRunningMessage(VMPaths.key(number)), stopsBackend: false)
        }
        update(number) { $0.state = .cloning }
        do {
            try await backend.prepareClone(slot: number)
            guard isCurrent(number, generation) else { return }
            update(number) { $0.state = .starting }
            let adaptor = try await backend.start(slot: number, generation: generation, worktree: slot(number)?.lease?.worktree)
            guard isCurrent(number, generation) else { return }
            displays[number] = adaptor
            let ip = try await backend.waitUntilReady(slot: number) { [weak self] ip in
                guard let self, isCurrent(number, generation) else { return }
                update(number) { $0.ip = ip }
            }
            guard isCurrent(number, generation) else { return }
            update(number) {
                $0.ip = ip
                $0.state = .ready
            }
            deadlineTasks[number]?.cancel()
        } catch {
            fail(number, generation: generation, error: error)
        }
    }

    private func fail(_ number: Int, generation: UInt64, error: any Error) {
        if Self.isPoolLimit(error) {
            fail(number, generation: generation, message: Failure.poolFull.localizedDescription
                + ": the host already runs as many macOS VMs as Virtualization allows, another app's included", poolFull: true)
        } else {
            fail(number, generation: generation, message: error.localizedDescription)
        }
    }

    /// Keeps the lease, so the claimant polling `vms.status` sees why; it releases the slot.
    private func fail(_ number: Int, generation: UInt64, message: String, poolFull: Bool = false, stopsBackend: Bool = true) {
        guard isCurrent(number, generation) else { return }
        deadlineTasks[number]?.cancel()
        let ip = slot(number)?.ip
        update(number) {
            $0.generation += 1
            $0.state = .failed
            $0.error = message
            $0.poolFull = poolFull
            $0.ip = nil
        }
        displays[number] = nil
        if stopsBackend { stopBackend(number, ip: ip, finalState: nil) }
    }

    private func guestStopped(_ number: Int, generation: UInt64, reason: String?) {
        guard let current = slot(number), current.generation == generation,
              current.state == .starting || current.state == .ready
        else { return }
        bootTasks[number]?.cancel()
        fail(number, generation: current.generation, message: "\(current.key) stopped" + (reason.map { ": \($0)" } ?? ""))
    }

    static func isPoolLimit(_ error: any Error) -> Bool {
        let error = error as NSError
        return error.domain == VZErrorDomain && error.code == VZError.Code.virtualMachineLimitExceeded.rawValue
    }

    private func isCurrent(_ number: Int, _ generation: UInt64) -> Bool {
        slot(number)?.generation == generation
    }

    // MARK: Stop

    private func stopSlot(_ number: Int) {
        bootTasks[number]?.cancel()
        deadlineTasks[number]?.cancel()
        let ip = slot(number)?.ip
        update(number) {
            $0.generation += 1
            $0.lease = nil
            $0.state = .stopping
            $0.ip = nil
            $0.error = nil
            $0.poolFull = false
        }
        displays[number] = nil
        stopBackend(number, ip: ip, finalState: .idle)
    }

    /// Chained after the slot's boot and any stop already running, so the backend sees them in
    /// order: a boot step still in flight, such as taking the clone lock, finishes before the
    /// stop that has to undo it.
    private func stopBackend(_ number: Int, ip: String?, finalState: VMSlotState?) {
        let generation = slot(number)!.generation
        let previous = stopTasks[number]
        let boot = bootTasks[number]
        let backend = backend
        let id = UUID()
        let task = Task { [weak self] in
            await boot?.value
            await previous?.value
            let stopped = await backend.stop(slot: number, ip: ip)
            guard let self else { return }
            if stopIDs[number] == id {
                stopTasks[number] = nil
                stopIDs[number] = nil
            }
            update(number) { $0.stillRunning = !stopped }
            guard isCurrent(number, generation) else { return }
            if !stopped {
                update(number) {
                    $0.state = .failed
                    $0.error = Self.stillRunningMessage($0.key)
                }
            } else if let finalState {
                update(number) { $0.state = finalState }
            }
        }
        stopTasks[number] = task
        stopIDs[number] = id
    }

    /// Stops every VM for a quit, returning once all have stopped or a forced stop has failed.
    /// Boot steps still on the host, such as `tart clone`, end at once.
    func stopAllForTermination() async {
        backend.beginTermination(gracePeriod: Self.terminationGracePeriod)
        for slot in slots where (slot.state != .idle && slot.state != .resetting) || slot.stillRunning {
            if slot.state == .failed {
                stopBackend(slot.number, ip: nil, finalState: nil)
            } else {
                stopSlot(slot.number)
            }
        }
        for task in Array(stopTasks.values) { await task.value }
    }

    // MARK: Reporting

    func info(_ number: Int) -> VMLeaseInfo {
        let slot = slot(number)!
        let lease = slot.lease
        let worktree = lease?.worktree
        return VMLeaseInfo(
            key: slot.key,
            state: slot.state,
            clone: VMPaths.cloneName(slot: number, os: backend.hostOSMajor),
            ip: slot.ip,
            share: VMPaths.share(number),
            worktree: worktree,
            guestWorktree: worktree == nil ? nil : VMPaths.guestWorktree,
            controlSocket: VMPaths.controlSocket(number),
            owner: lease?.owner,
            leaseToken: lease?.token,
            branch: lease?.branch,
            claimedAt: lease?.claimedAt,
            expiresAt: lease?.expiresAt,
            installed: lease?.installed,
            error: slot.error,
            poolFull: slot.poolFull ? true : nil,
            heldElsewhere: slot.state == .idle && lease == nil && heldElsewhere.contains(number) ? true : nil
        )
    }

    func refreshHeldElsewhere() async {
        heldElsewhere = await backend.clonesHeldElsewhere()
    }

    private nonisolated static func resolved(_ worktree: String?) async -> String? {
        guard let worktree else { return nil }
        return await Task.detached(priority: .userInitiated) { CLIPath.resolved(worktree) }.value
    }

    func info(forKey key: String) throws -> VMLeaseInfo {
        guard let number = VMPaths.slot(fromKey: key) else { throw Failure.unknownKey(key) }
        return info(number)
    }

    var allInfo: [VMLeaseInfo] { slots.map { info($0.number) } }

    private func update(_ number: Int, _ change: (inout Slot) -> Void) {
        guard let index = slots.firstIndex(where: { $0.number == number }) else { return }
        change(&slots[index])
    }
}
