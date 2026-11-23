import Foundation
import Virtualization

/// What `VMManager` asks of the host, so its lease and state logic runs against a fake in tests.
/// Every method for one slot runs in the order called; `stop` frees whatever the slot holds, and is
/// harmless when it holds nothing.
protocol VMBackend: AnyObject {
    var hostOSMajor: Int { get }
    /// Called when a guest stops on its own, not through `stop`: a guest-side shutdown or a crash.
    var guestDidStop: ((_ slot: Int, _ reason: String?) -> Void)? { get set }

    func baseImageExists() -> Bool
    /// Whether no process holds the slot's clone lock. Only asked of a slot this app isn't running.
    func isCloneFree(slot: Int) -> Bool
    /// Takes the clone's lock, cloning from the base if the clone is missing.
    func prepareClone(slot: Int) async throws
    /// What a `VZVirtualMachineView` shows the VM through.
    func start(slot: Int, worktree: String?) async throws -> VMDisplay?
    /// The guest's address, once ssh answers and the user's console session is unlocked.
    /// `onAddress` hears each address as it's found, before the guest is ready.
    func waitUntilReady(slot: Int, onAddress: (String) -> Void) async throws -> String
    func stop(slot: Int, ip: String?) async
    func deleteClone(slot: Int) async throws
}

/// Virtualization on one serial queue per slot, which every call on that slot's
/// `VZVirtualMachine` must use. The VM, its delegate and the clone lock never leave that queue.
final class LiveVMBackend: VMBackend {
    let hostOSMajor = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    var guestDidStop: ((_ slot: Int, _ reason: String?) -> Void)?

    static let gracefulStopWait: TimeInterval = 12
    static let readinessPollInterval: Duration = .seconds(2)

    private var runtimes: [Int: VMRuntime] = [:]

    private func runtime(_ slot: Int) -> VMRuntime {
        if let runtime = runtimes[slot] { return runtime }
        let runtime = VMRuntime(slot: slot, clone: VMPaths.cloneName(slot: slot, os: hostOSMajor))
        runtime.onGuestStop = { [weak self] slot, reason in
            Task { @MainActor in self?.guestDidStop?(slot, reason) }
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
        try await runtime(slot).perform { runtime in
            if runtime.lock == nil {
                guard let lock = VMCloneLock.acquire(path: VMPaths.lockFile(clone: runtime.clone)) else {
                    throw VMHost.Failure(message: "another Plume is running \(runtime.clone)")
                }
                runtime.lock = lock
            }
            if !VMHost.vmExists(runtime.clone) {
                try VMHost.clone(base: base, to: runtime.clone)
            }
        }
    }

    func start(slot: Int, worktree: String?) async throws -> VMDisplay? {
        try await runtime(slot).start(worktree: worktree)
    }

    /// The DHCP lease is read again on every poll, since the guest can be handed a new address.
    func waitUntilReady(slot: Int, onAddress: (String) -> Void) async throws -> String {
        let runtime = runtime(slot)
        guard let mac = try await runtime.perform({ $0.macAddress }) else {
            throw VMHost.Failure(message: "\(runtime.clone) isn't running")
        }
        var reported: String?
        while true {
            try Task.checkCancellation()
            let ip = await Task.detached(priority: .utility) { VMHost.ipAddress(forMAC: mac) }.value
            if let ip {
                if ip != reported {
                    reported = ip
                    onAddress(ip)
                }
                if let result = try? await VMHost.ssh(ip: ip, command: VMHost.readinessQuery, timeout: .seconds(10)),
                   result.status == 0,
                   VMHost.isReady(readinessOutput: result.stdout, mac: mac) {
                    return ip
                }
            }
            try await Task.sleep(for: Self.readinessPollInterval)
        }
    }

    /// `requestStop()` doesn't shut a logged-in guest down, so the guest is asked over ssh and
    /// `stop()` is the fallback.
    func stop(slot: Int, ip: String?) async {
        let runtime = runtime(slot)
        let running = (try? await runtime.perform { runtime -> Bool in
            runtime.isStopping = true
            return runtime.machine != nil
        }) ?? false
        if running {
            if let ip { _ = try? await VMHost.ssh(ip: ip, command: "sudo shutdown -h now", timeout: .seconds(8)) }
            await runtime.waitUntilStopped(timeout: Self.gracefulStopWait)
        }
        await runtime.tearDown()
    }

    func deleteClone(slot: Int) async throws {
        try await runtime(slot).perform { runtime in
            guard runtime.lock == nil, let lock = VMCloneLock.acquire(path: VMPaths.lockFile(clone: runtime.clone)) else {
                throw VMHost.Failure(message: "another Plume is running \(runtime.clone)")
            }
            defer { lock.release() }
            if VMHost.vmExists(runtime.clone) { try VMHost.delete(runtime.clone) }
        }
    }
}

/// One slot's VM. Every stored property is touched only on `queue`.
nonisolated final class VMRuntime: NSObject, VZVirtualMachineDelegate, @unchecked Sendable {
    let slot: Int
    let clone: String
    let queue: DispatchQueue
    var onGuestStop: (@Sendable (_ slot: Int, _ reason: String?) -> Void)?

    var lock: VMCloneLock?
    var machine: VZVirtualMachine?
    var macAddress: String?
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

    func start(worktree: String?) async throws -> VMDisplay? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<VMDisplay?, any Error>) in
            queue.async { [self] in
                do {
                    guard lock != nil else { throw VMHost.Failure(message: "\(clone) isn't locked") }
                    let directory = VMHost.vmDirectory(clone)
                    let share = URL(fileURLWithPath: VMPaths.share(slot), isDirectory: true)
                    try FileManager.default.createDirectory(at: share, withIntermediateDirectories: true)
                    let worktreeURL = worktree.map { URL(fileURLWithPath: $0, isDirectory: true) }
                    let configuration = try VMImage.configuration(cloneDirectory: directory, worktree: worktreeURL, share: share)
                    let config = try TartVMConfig.parse(Data(contentsOf: directory.appending(path: TartVMConfig.fileName)))
                    let machine = VZVirtualMachine(configuration: configuration, queue: queue)
                    machine.delegate = self
                    self.machine = machine
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

    /// Waits for the guest to stop, then forces it. It returns only once the VM has stopped, so
    /// the clone lock is never released while the VM still holds the disk: a VM that can't be
    /// stopped yet, such as one still starting, is waited on until it can.
    func waitUntilStopped(timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let status = try? await perform { runtime in
                runtime.machine.map { (state: $0.state, canStop: $0.canStop) }
            }
            guard let status, status.state != .stopped, status.state != .error else { return }
            if Date() >= deadline, status.canStop {
                await forceStop()
                return
            }
            try? await Task.sleep(for: .milliseconds(500))
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

    func tearDown() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                machine?.delegate = nil
                machine = nil
                macAddress = nil
                lock?.release()
                lock = nil
                isStopping = false
                continuation.resume()
            }
        }
    }

    // MARK: VZVirtualMachineDelegate, called on `queue`

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        guard !isStopping else { return }
        onGuestStop?(slot, nil)
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: any Error) {
        guard !isStopping else { return }
        onGuestStop?(slot, error.localizedDescription)
    }
}

/// A running VM as a view shows it. Made on the VM's queue, and attached on the main actor.
nonisolated final class VMDisplay: @unchecked Sendable {
    private let machine: VZVirtualMachine
    /// A `VZVirtualMachineViewAdaptor` on macOS 27, which hands the VM to the view across isolation.
    private let adaptor: Any?

    init(machine: VZVirtualMachine) {
        self.machine = machine
        if #available(macOS 27.0, *) {
            adaptor = VZVirtualMachineViewAdaptor(virtualMachine: machine)
        } else {
            adaptor = nil
        }
    }

    @MainActor
    func attach(to view: VZVirtualMachineView) {
        if #available(macOS 27.0, *), let adaptor = adaptor as? VZVirtualMachineViewAdaptor {
            view.adaptor = adaptor
        } else {
            view.virtualMachine = machine
        }
    }

    @MainActor
    static func detach(from view: VZVirtualMachineView) {
        view.virtualMachine = nil
    }
}
