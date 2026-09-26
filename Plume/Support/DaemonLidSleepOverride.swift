import AppKit
import Foundation
import Observation
import os
import ServiceManagement

/// Drives `PlumeSleepHelper`, the root LaunchDaemon that flips `SleepDisabled`.
///
/// The helper owns crash safety (it clears the override when this connection
/// dies or its lease lapses), so this side only has to keep the lease renewed
/// while the override is wanted and re-engage after the helper restarts.
@MainActor
@Observable
final class DaemonLidSleepOverride: LidSleepOverride {
    private(set) var status: LidSleepOverrideStatus = .notRegistered

    @ObservationIgnored private let service = SMAppService.daemon(plistName: sleepHelperPlistName)
    @ObservationIgnored private var connection: NSXPCConnection?
    @ObservationIgnored private var heartbeat: Timer?
    @ObservationIgnored private var approvalPoll: Timer?
    @ObservationIgnored private var activationObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var wantsEngaged = false
    @ObservationIgnored private var isEngaged = false
    @ObservationIgnored private var engagePending = false
    @ObservationIgnored private var retryPolicy = SleepHelperRetryPolicy()
    @ObservationIgnored private var retryTimer: Timer?
    /// Set from a failed engage until its retry is scheduled, so nothing
    /// re-engages while the launchd probe or a re-register is in flight.
    @ObservationIgnored private var isRecovering = false

    /// The daemon's designated identity, so a process squatting on the Mach
    /// service name cannot impersonate it.
    private static let helperRequirement =
        "anchor apple generic and certificate leaf[subject.OU] = \"\(sleepHelperTeamID)\""
        + " and identifier \"\(sleepHelperServiceName)\""

    init() {
        refreshStatus()
        if service.status == .enabled {
            Task { await reregisterIfNotLoaded() }
        }
        // Approval happens in System Settings, so coming back to Plume is the
        // moment the status is most likely to have changed.
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshStatus() }
        }
    }

    // MARK: - LidSleepOverride

    func refreshStatus() {
        switch service.status {
        // A daemon that has never been registered reads `.notFound`; `.notRegistered`
        // only appears after an unregister. Both mean "register me".
        case .notRegistered, .notFound:
            set(.notRegistered)
            stopApprovalPoll()
        case .requiresApproval:
            set(.needsApproval)
            startApprovalPoll()
        case .enabled:
            if retryPolicy.isUnavailable {
                set(.unavailable(Self.unresponsiveReason))
            } else {
                set(isEngaged ? .engaged : .ready)
            }
            stopApprovalPoll()
            if wantsEngaged, !isEngaged { engage() }
        @unknown default:
            set(.unavailable("Unknown helper state \(service.status.rawValue)."))
        }
    }

    func ensureRegistered() {
        guard status == .notRegistered else { return }
        do {
            try service.register()
            Log.app.notice("Registered the sleep helper")
        } catch {
            // A daemon's first registration reports "Operation not permitted"
            // and lands in requiresApproval; that is the approval flow, not a
            // failure. Anything else surfaces through the status read below.
            Log.app.notice("Sleep helper registration: \(error.localizedDescription, privacy: .public)")
        }
        refreshStatus()
        if status == .notRegistered {
            set(.unavailable("macOS refused to register the sleep helper."))
        }
    }

    func unregister() {
        guard status != .notRegistered else { return }
        apply(false)
        stopRetry()
        retryPolicy = SleepHelperRetryPolicy()
        connection?.invalidate()
        connection = nil
        do {
            try service.unregister()
            Log.app.notice("Sleep helper unregistered")
        } catch {
            set(.unavailable("macOS refused to remove the sleep helper: \(error.localizedDescription)"))
            Log.app.error("Sleep helper unregister failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        refreshStatus()
    }

    func reinstall() {
        stopRetry()
        retryPolicy = SleepHelperRetryPolicy()
        connection?.invalidate()
        connection = nil
        isEngaged = false
        engagePending = false
        stopHeartbeat()
        isRecovering = true
        Task {
            await reregister()
            isRecovering = false
            refreshStatus()
        }
    }

    func apply(_ engaged: Bool) {
        wantsEngaged = engaged
        if engaged {
            guard service.status == .enabled else {
                refreshStatus()
                return
            }
            engage()
        } else {
            disengage()
        }
    }

    // MARK: - Engaging

    private func engage() {
        guard !isEngaged, !engagePending, !isRecovering, retryTimer == nil else { return }
        engagePending = true
        let helper = proxy { [weak self] in
            Task { @MainActor in self?.engageFailed() }
        }
        helper?.setSleepDisabled(true) { [weak self] now, error in
            Task { @MainActor in self?.didEngage(now: now, error: error) }
        }
    }

    private func didEngage(now: Bool, error: String?) {
        engagePending = false
        let wasUnavailable = retryPolicy.isUnavailable
        retryPolicy.recordSuccess()
        if wasUnavailable { refreshStatus() }
        guard wantsEngaged else {
            // The hold ended while the request was in flight.
            if now { proxy()?.setSleepDisabled(false) { _, _ in } }
            return
        }
        if now {
            isEngaged = true
            set(.engaged)
            startHeartbeat()
            Log.app.notice("Lid-closed override engaged")
        } else {
            set(.unavailable(error ?? "The sleep helper could not set the override."))
            Log.app.error("Lid-closed override failed: \(error ?? "no reason", privacy: .public)")
        }
    }

    private func disengage() {
        stopHeartbeat()
        guard isEngaged || engagePending else { return }
        isEngaged = false
        engagePending = false
        let sleepIfLidClosed = !ExternalDisplay.isConnected
        proxy()?.releaseOverride(sleepIfLidClosed: sleepIfLidClosed) { _, _ in }
        Log.app.notice("Lid-closed override released (sleepIfLidClosed=\(sleepIfLidClosed))")
        refreshStatus()
    }

    // MARK: - Recovery

    private static let unresponsiveReason =
        "The sleep helper isn't responding. Reinstall it from Settings → Keep Awake."

    /// XPC calls exactly one of a message's reply or its error handler, so
    /// this runs once per failed engage, however the connection died.
    private func engageFailed() {
        engagePending = false
        isRecovering = true
        let delay = retryPolicy.recordFailure()
        Log.app.error(
            "Sleep helper unreachable (\(self.retryPolicy.consecutiveFailures) in a row); retrying in \(delay, privacy: .public)s"
        )
        refreshStatus()
        Task {
            await reregisterIfNotLoaded()
            isRecovering = false
            scheduleRetry(after: delay)
        }
    }

    private func scheduleRetry(after delay: TimeInterval) {
        stopRetry()
        retryTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.retryTimer = nil
                self.refreshStatus()
            }
        }
    }

    private func stopRetry() {
        retryTimer?.invalidate()
        retryTimer = nil
    }

    /// A Homebrew upgrade's `launchctl` uninstall step leaves the helper
    /// approved but unloaded, and launchd will not load it again by itself.
    private func reregisterIfNotLoaded() async {
        guard !retryPolicy.hasReregistered else { return }
        let loaded = await Self.isHelperLoaded()
        guard retryPolicy.claimReregister(helperLoaded: loaded) else { return }
        Log.app.notice("Sleep helper is approved but not loaded; re-registering")
        await reregister()
    }

    /// Unregister-then-register is what reloaded an unloaded job by hand, and
    /// macOS keeps the approval across it, so it does not prompt.
    private func reregister() async {
        do {
            try await service.unregister()
        } catch {
            Log.app.notice("Sleep helper unregister before re-register: \(error.localizedDescription, privacy: .public)")
        }
        do {
            try service.register()
            Log.app.notice("Re-registered the sleep helper")
        } catch {
            Log.app.error("Sleep helper re-register failed: \(error.localizedDescription, privacy: .public)")
        }
        refreshStatus()
    }

    /// Reports loaded when `launchctl` itself cannot run, so nothing is
    /// re-registered on a guess.
    private nonisolated static func isHelperLoaded() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
                process.arguments = ["print", "system/\(sleepHelperServiceName)"]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                    process.waitUntilExit()
                    continuation.resume(returning: process.terminationStatus == 0)
                } catch {
                    continuation.resume(returning: true)
                }
            }
        }
    }

    // MARK: - Lease

    private func startHeartbeat() {
        heartbeat?.invalidate()
        heartbeat = Timer.scheduledTimer(withTimeInterval: sleepHelperHeartbeatInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sendHeartbeat() }
        }
    }

    private func stopHeartbeat() {
        heartbeat?.invalidate()
        heartbeat = nil
    }

    /// A `false` reply means the helper no longer knows this lease — it
    /// restarted, or the lease lapsed — so the override has to be re-asked.
    private func sendHeartbeat() {
        proxy()?.heartbeat { [weak self] alive in
            guard !alive else { return }
            Task { @MainActor in
                guard let self else { return }
                self.isEngaged = false
                if self.wantsEngaged { self.engage() }
            }
        }
    }

    // MARK: - Connection

    private func proxy(onError: (@Sendable () -> Void)? = nil) -> (any SleepHelperProtocol)? {
        if connection == nil {
            let connection = NSXPCConnection(machServiceName: sleepHelperServiceName, options: .privileged)
            connection.remoteObjectInterface = NSXPCInterface(with: SleepHelperProtocol.self)
            connection.setCodeSigningRequirement(Self.helperRequirement)
            connection.invalidationHandler = { [weak self, weak connection] in
                Task { @MainActor in self?.connectionDropped(connection) }
            }
            connection.interruptionHandler = { [weak self, weak connection] in
                Task { @MainActor in self?.connectionDropped(connection) }
            }
            connection.resume()
            self.connection = connection
        }
        return connection?.remoteObjectProxyWithErrorHandler { error in
            Log.app.error("Sleep helper XPC error: \(error.localizedDescription, privacy: .public)")
            onError?()
        } as? any SleepHelperProtocol
    }

    /// The helper clears the override when a connection dies, so anything
    /// still wanted has to be asked for again over a fresh connection. A
    /// pending engage is left to its error handler, which backs off.
    private func connectionDropped(_ dropped: NSXPCConnection?) {
        guard let dropped, dropped === connection else { return }
        // An interrupted connection stays valid; invalidating it keeps it from
        // living on beside its replacement.
        dropped.invalidate()
        connection = nil
        isEngaged = false
        stopHeartbeat()
        refreshStatus()
    }

    // MARK: - Approval

    /// `SMAppService.status` is not observable, and the approval happens in
    /// another app, so poll while it is the only thing left to wait for.
    private func startApprovalPoll() {
        guard approvalPoll == nil else { return }
        approvalPoll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshStatus() }
        }
    }

    private func stopApprovalPoll() {
        approvalPoll?.invalidate()
        approvalPoll = nil
    }

    private func set(_ new: LidSleepOverrideStatus) {
        if status != new { status = new }
    }
}
