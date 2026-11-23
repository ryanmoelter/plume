import Foundation
import Synchronization
import Virtualization

/// What `VMManager` asks of the host, so its lease and state logic runs against a fake in tests.
/// Every method for one slot runs in the order called; `stop` frees whatever the slot holds, and is
/// harmless when it holds nothing.
protocol VMBackend: AnyObject {
    var hostOSMajor: Int { get }
    /// Called when a guest stops on its own, not through `stop`: a guest-side shutdown or a crash.
    /// `generation` is the one passed to the `start` that booted it.
    var guestDidStop: ((_ slot: Int, _ generation: UInt64, _ reason: String?) -> Void)? { get set }

    func baseImageExists() -> Bool
    /// Whether no process holds the slot's clone lock. Only asked of a slot this app isn't running.
    func isCloneFree(slot: Int) -> Bool
    /// Takes the clone's lock, cloning from the base if the clone is missing.
    func prepareClone(slot: Int) async throws
    /// What a `VZVirtualMachineView` shows the VM through.
    func start(slot: Int, generation: UInt64, worktree: String?) async throws -> VMDisplay?
    /// The guest's address, once ssh answers and the user's console session is unlocked.
    /// `onAddress` hears each address as it's found, once the guest there has shown this VM's MAC.
    func waitUntilReady(slot: Int, onAddress: (String) -> Void) async throws -> String
    /// False when the VM is still running after a forced stop, which keeps the clone locked.
    func stop(slot: Int, ip: String?) async -> Bool
    func deleteClone(slot: Int) async throws
    /// Ends every `tart` command at once, and cuts every graceful stop, running or to come, to
    /// `gracePeriod` from now before it forces the VM.
    func beginTermination(gracePeriod: TimeInterval)
}

/// Virtualization on one serial queue per slot, which every call on that slot's
/// `VZVirtualMachine` must use. The VM, its delegate and the clone lock never leave that queue.
final class LiveVMBackend: VMBackend {
    let hostOSMajor = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    var guestDidStop: ((_ slot: Int, _ generation: UInt64, _ reason: String?) -> Void)?

    static let gracefulStopWait: TimeInterval = 20
    static let shutdownCommandTimeout: TimeInterval = 8
    static let readinessPollInterval: Duration = .seconds(2)

    private var runtimes: [Int: VMRuntime] = [:]
    private let termination = VMTermination()

    private func runtime(_ slot: Int) -> VMRuntime {
        if let runtime = runtimes[slot] { return runtime }
        let runtime = VMRuntime(slot: slot, clone: VMPaths.cloneName(slot: slot, os: hostOSMajor))
        runtime.onGuestStop = { [weak self] slot, generation, reason in
            Task { @MainActor in self?.guestDidStop?(slot, generation, reason) }
        }
        runtimes[slot] = runtime
        return runtime
    }

    func baseImageExists() -> Bool {
        VMHost.vmExists(VMPaths.baseName(os: hostOSMajor))
    }

    func isCloneFree(slot: Int) -> Bool {
        VMCloneLock.isFree(path: VMPaths.lockFile(clone: VMPaths.cloneName(slot: slot, os: hostOSMajor)))
    }

    func prepareClone(slot: Int) async throws {
        let base = VMPaths.baseName(os: hostOSMajor)
        let termination = termination
        try await runtime(slot).perform { runtime in
            if termination.isTerminating { throw CancellationError() }
            if runtime.lock == nil {
                guard let lock = VMCloneLock.acquire(path: VMPaths.lockFile(clone: runtime.clone)) else {
                    throw VMHost.Failure(message: "another Plume is running \(runtime.clone)")
                }
                runtime.lock = lock
            }
            if !VMHost.vmExists(runtime.clone) {
                try VMHost.clone(base: base, to: runtime.clone, isCancelled: { termination.isTerminating })
            }
        }
    }

    func start(slot: Int, generation: UInt64, worktree: String?) async throws -> VMDisplay? {
        try await runtime(slot).start(generation: generation, worktree: worktree)
    }

    /// The DHCP lease is read again on every poll, since the guest can be handed a new address. An
    /// address counts only once the guest there shows this VM's MAC, since a stale lease can name
    /// another clone.
    func waitUntilReady(slot: Int, onAddress: (String) -> Void) async throws -> String {
        let runtime = runtime(slot)
        guard let mac = try await runtime.perform({ $0.macAddress }) else {
            throw VMHost.Failure(message: "\(runtime.clone) isn't running")
        }
        var reported: String?
        while true {
            try Task.checkCancellation()
            let ip = await Task.detached(priority: .utility) { VMHost.ipAddress(forMAC: mac) }.value
            if let ip,
               let result = try? await VMHost.ssh(ip: ip, command: VMHost.readinessQuery, timeout: .seconds(10)),
               result.status == 0,
               VMHost.readinessShowsMAC(result.stdout, mac: mac) {
                if ip != reported {
                    reported = ip
                    onAddress(ip)
                }
                if VMHost.isReady(readinessOutput: result.stdout, mac: mac) { return ip }
            }
            try await Task.sleep(for: Self.readinessPollInterval)
        }
    }

    /// `requestStop()` doesn't shut a logged-in guest down, so the guest is asked over ssh and
    /// `stop()` is the fallback.
    func stop(slot: Int, ip: String?) async -> Bool {
        let runtime = runtime(slot)
        let termination = termination
        let ownGraceEnd = Date().addingTimeInterval(Self.gracefulStopWait)
        let graceEnd: @Sendable () -> Date = { min(ownGraceEnd, termination.graceEnd ?? .distantFuture) }
        let running = (try? await runtime.perform { runtime -> (mac: String?, isRunning: Bool) in
            runtime.isStopping = true
            return (runtime.macAddress, runtime.machine != nil)
        }) ?? (mac: nil, isRunning: false)
        if running.isRunning {
            let shutdownTimeout = min(Self.shutdownCommandTimeout, graceEnd().timeIntervalSinceNow)
            if let ip, let mac = running.mac, shutdownTimeout > 0 {
                _ = try? await VMHost.ssh(ip: ip, command: VMHost.shutdownCommand(mac: mac), timeout: .seconds(shutdownTimeout))
            }
            await runtime.waitUntilStopped(graceEnd: graceEnd)
        }
        return await runtime.tearDown()
    }

    func deleteClone(slot: Int) async throws {
        let termination = termination
        try await runtime(slot).perform { runtime in
            guard runtime.lock == nil, let lock = VMCloneLock.acquire(path: VMPaths.lockFile(clone: runtime.clone)) else {
                throw VMHost.Failure(message: "another Plume is running \(runtime.clone)")
            }
            defer { lock.release() }
            if VMHost.vmExists(runtime.clone) { try VMHost.delete(runtime.clone, isCancelled: { termination.isTerminating }) }
        }
    }

    func beginTermination(gracePeriod: TimeInterval) {
        termination.begin(graceEnd: Date().addingTimeInterval(gracePeriod))
    }
}

/// Set once, when the app quits, and read from the slots' queues.
nonisolated final class VMTermination: Sendable {
    private let state = Mutex<Date?>(nil)

    var graceEnd: Date? { state.withLock { $0 } }
    var isTerminating: Bool { graceEnd != nil }

    func begin(graceEnd: Date) {
        state.withLock { $0 = $0 ?? graceEnd }
    }
}

/// One slot's VM. Every stored property is touched only on `queue`.
nonisolated final class VMRuntime: NSObject, VZVirtualMachineDelegate, @unchecked Sendable {
    let slot: Int
    let clone: String
    let queue: DispatchQueue
    var onGuestStop: (@Sendable (_ slot: Int, _ generation: UInt64, _ reason: String?) -> Void)?

    var lock: VMCloneLock?
    var machine: VZVirtualMachine?
    var macAddress: String?
    var generation: UInt64 = 0
    var isStopping = false

    init(slot: Int, clone: String) {
        self.slot = slot
        self.clone = clone
        queue = DispatchQueue(label: "com.ryanmoelter.Plume.vm\(slot)", qos: .userInitiated)
    }

    func perform<T: Sendable>(_ body: @escaping @Sendable (VMRuntime) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try body(self) }) }
        }
    }

    func start(generation: UInt64, worktree: String?) async throws -> VMDisplay? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<VMDisplay?, any Error>) in
            queue.async { [self] in
                do {
                    guard #available(macOS 27.0, *) else { throw VMHost.Failure(message: VMManager.unsupportedMessage) }
                    guard lock != nil else { throw VMHost.Failure(message: "\(clone) isn't locked") }
                    guard machine == nil else {
                        throw VMHost.Failure(message: "\(clone)'s previous VM hasn't stopped; quit Plume to end it")
                    }
                    let directory = VMHost.vmDirectory(clone)
                    let share = URL(fileURLWithPath: VMPaths.share(slot), isDirectory: true)
                    try FileManager.default.createDirectory(at: share, withIntermediateDirectories: true)
                    let worktreeURL = worktree.map { URL(fileURLWithPath: $0, isDirectory: true) }
                    let configuration = try VMImage.configuration(cloneDirectory: directory, worktree: worktreeURL, share: share)
                    let config = try TartVMConfig.parse(Data(contentsOf: directory.appending(path: TartVMConfig.fileName)))
                    let machine = VZVirtualMachine(configuration: configuration, queue: queue)
                    machine.delegate = self
                    self.machine = machine
                    self.generation = generation
                    macAddress = config.macAddress
                    isStopping = false
                    let display = VMDisplay(machine: machine)
                    machine.start { result in
                        continuation.resume(with: result.map { display })
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static let forcedStopAttempts = 2

    /// Waits for the guest to stop until `graceEnd`, then forces it, trying twice. A VM that can't
    /// be stopped yet, such as one still starting, is waited on until it can.
    func waitUntilStopped(graceEnd: @Sendable () -> Date) async {
        var forcedStops = 0
        while true {
            let status = try? await perform { runtime in
                runtime.machine.map { (state: $0.state, canStop: $0.canStop) }
            }
            guard let status, status.state != .stopped, status.state != .error else { return }
            if Date() >= graceEnd(), status.canStop {
                guard forcedStops < Self.forcedStopAttempts else { return }
                forcedStops += 1
                await forceStop()
            } else {
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func forceStop() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                guard let machine, machine.canStop else { return continuation.resume() }
                machine.stop { _ in continuation.resume() }
            }
        }
    }

    /// Frees the clone only once the VM has stopped, since the VM still holds its disk until then.
    /// Returns whether it did.
    func tearDown() async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            queue.async { [self] in
                if let machine, machine.state != .stopped, machine.state != .error {
                    return continuation.resume(returning: false)
                }
                machine?.delegate = nil
                machine = nil
                macAddress = nil
                lock?.release()
                lock = nil
                isStopping = false
                continuation.resume(returning: true)
            }
        }
    }

    // MARK: VZVirtualMachineDelegate, called on `queue`

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        guard !isStopping else { return }
        onGuestStop?(slot, generation, nil)
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: any Error) {
        guard !isStopping else { return }
        onGuestStop?(slot, generation, error.localizedDescription)
    }
}

/// A running VM as a view shows it. Made on the VM's queue, and attached on the main actor through
/// a `VZVirtualMachineViewAdaptor`, which hands the VM to the view across isolation.
nonisolated final class VMDisplay: @unchecked Sendable {
    private let adaptor: Any

    @available(macOS 27.0, *)
    init(machine: VZVirtualMachine) {
        adaptor = VZVirtualMachineViewAdaptor(virtualMachine: machine)
    }

    @available(macOS 27.0, *)
    @MainActor
    func attach(to view: VZVirtualMachineView) {
        view.adaptor = adaptor as? VZVirtualMachineViewAdaptor
    }

    @available(macOS 27.0, *)
    @MainActor
    static func detach(from view: VZVirtualMachineView) {
        view.adaptor = nil
        view.virtualMachine = nil
    }
}
