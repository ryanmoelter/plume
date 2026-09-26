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
    @ObservationIgnored private var probePending = false
    @ObservationIgnored private var retryPolicy = SleepHelperRetryPolicy()
    @ObservationIgnored private var retryTimer: Timer?
    /// Set from a failed engage until its retry is scheduled, and through a
    /// reinstall, so nothing engages while launchd is being asked or changed.
    @ObservationIgnored private var isRecovering = false
    /// Bumped by uninstall and reinstall. Recovery work that suspended across
    /// one checks it on resuming, so it never re-registers a helper the user
    /// removed or races a reinstall.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var versionPolicy = SleepHelperVersionPolicy(
        appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
    )
    @ObservationIgnored private var deferredReinstallTimer: Timer?

    /// The daemon's designated identity, so a process squatting on the Mach
    /// service name cannot impersonate it.
    private nonisolated static let helperRequirement =
        "anchor apple generic and certificate leaf[subject.OU] = \"\(sleepHelperTeamID)\""
        + " and identifier \"\(sleepHelperServiceName)\""

    /// The test host is the Debug app, and launchd has one job for every
    /// Plume install, so a test run must never re-register it on its own.
    private static let changesRegistrationOnItsOwn =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
        && NSClassFromString("XCTestCase") == nil

    init() {
        readStatus()
        if status == .ready, Self.changesRegistrationOnItsOwn {
            let generation = generation
            Task { await reregisterIfNotLoaded(generation: generation) }
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

    /// With no hold wanting the helper, nothing else retries it, so an
    /// unresponsive helper is asked again here, on the user's return.
    func refreshStatus() {
        readStatus()
        if status == .unresponsive, !wantsEngaged { checkResponsive() }
    }

    func ensureRegistered() {
        guard status == .notRegistered else { return }
        do {
            try service.register()
            versionPolicy.recordManualReinstall()
            Log.app.notice("Registered the sleep helper")
        } catch {
            // A daemon's first registration reports "Operation not permitted"
            // and lands in requiresApproval; that is the approval flow, not a
            // failure. Anything else surfaces through the status read below.
            Log.app.notice("Sleep helper registration: \(error.localizedDescription, privacy: .public)")
        }
        readStatus()
        if status == .notRegistered {
            set(.unavailable("macOS refused to register the sleep helper."))
        }
    }

    func unregister() {
        guard status != .notRegistered else { return }
        apply(false)
        stopDeferredReinstall()
        resetRecovery()
        do {
            try service.unregister()
            Log.app.notice("Sleep helper unregistered")
        } catch {
            set(.unavailable("macOS refused to remove the sleep helper: \(error.localizedDescription)"))
            Log.app.error("Sleep helper unregister failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        readStatus()
    }

    func reinstall() {
        versionPolicy.recordManualReinstall()
        stopDeferredReinstall()
        resetRecovery()
        isEngaged = false
        engagePending = false
        stopHeartbeat()
        isRecovering = true
        let generation = generation
        Task {
            await reregister(generation: generation)
            guard generation == self.generation else { return }
            isRecovering = false
            readStatus()
        }
    }

    func apply(_ engaged: Bool) {
        wantsEngaged = engaged
        if engaged {
            guard service.status == .enabled else {
                readStatus()
                return
            }
            engage()
        } else {
            disengage()
        }
    }

    private func readStatus() {
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
            if retryPolicy.isUnresponsive {
                set(.unresponsive)
            } else {
                set(isEngaged ? .engaged : .ready)
            }
            stopApprovalPoll()
            if wantsEngaged, !isEngaged { engage() }
            if !retryPolicy.isUnresponsive { checkVersionIfNeeded() }
        @unknown default:
            set(.unavailable("Unknown helper state \(service.status.rawValue)."))
        }
    }

    // MARK: - Engaging

    private func engage() {
        guard !isEngaged, !engagePending, !isRecovering, retryTimer == nil else { return }
        engagePending = true
        let generation = generation
        let helper = proxy { [weak self] in
            Task { @MainActor in self?.engageFailed(generation: generation) }
        }
        helper?.setSleepDisabled(true) { [weak self] now, error in
            Task { @MainActor in self?.didEngage(now: now, error: error) }
        }
    }

    private func didEngage(now: Bool, error: String?) {
        engagePending = false
        let wasUnresponsive = retryPolicy.isUnresponsive
        retryPolicy.recordSuccess()
        guard wantsEngaged else {
            // The hold ended while the request was in flight.
            if now { proxy()?.setSleepDisabled(false) { _, _ in } }
            if wasUnresponsive { readStatus() }
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
        if versionPolicy.isReinstallDeferred { scheduleDeferredReinstall() }
        guard isEngaged || engagePending else { return }
        isEngaged = false
        engagePending = false
        let sleepIfLidClosed = !ExternalDisplay.isConnected
        proxy()?.releaseOverride(sleepIfLidClosed: sleepIfLidClosed) { _, _ in }
        Log.app.notice("Lid-closed override released (sleepIfLidClosed=\(sleepIfLidClosed))")
        readStatus()
    }

    // MARK: - Recovery

    /// XPC calls exactly one of a message's reply or its error handler, so
    /// this runs once per failed engage, however the connection died. An
    /// engage from before an uninstall or reinstall was torn down on purpose,
    /// so its failure says nothing about the helper.
    private func engageFailed(generation: Int) {
        guard generation == self.generation else { return }
        engagePending = false
        isRecovering = true
        let delay = retryPolicy.recordFailure()
        Log.app.error(
            "Sleep helper unreachable (\(self.retryPolicy.consecutiveFailures) in a row); retrying in \(delay, privacy: .public)s"
        )
        readStatus()
        Task {
            await reregisterIfNotLoaded(generation: generation)
            guard generation == self.generation else { return }
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
                self.readStatus()
            }
        }
    }

    private func stopRetry() {
        retryTimer?.invalidate()
        retryTimer = nil
    }

    /// Drops the connection, the back-off, and any recovery still suspended.
    private func resetRecovery() {
        generation += 1
        stopRetry()
        retryPolicy = SleepHelperRetryPolicy()
        isRecovering = false
        connection?.invalidate()
        connection = nil
    }

    /// Asks an unresponsive helper for its state; any answer means it is back.
    /// A failure only drops the connection, which does not come back here.
    private func checkResponsive() {
        guard !probePending else { return }
        probePending = true
        let generation = generation
        let helper = proxy { [weak self] in
            Task { @MainActor in self?.probePending = false }
        }
        helper?.currentState { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.probePending = false
                guard generation == self.generation else { return }
                self.retryPolicy.recordSuccess()
                self.readStatus()
            }
        }
    }

    /// A Homebrew upgrade's `launchctl` uninstall step leaves the helper
    /// approved but unloaded, and launchd will not load it again by itself.
    private func reregisterIfNotLoaded(generation: Int) async {
        guard Self.changesRegistrationOnItsOwn, !retryPolicy.hasCheckedLoad else { return }
        let loaded = await Self.isHelperLoaded()
        guard generation == self.generation,
              service.status == .enabled,
              retryPolicy.claimReregister(helperLoaded: loaded)
        else { return }
        Log.app.notice("Sleep helper is approved but not loaded; re-registering")
        await reregister(generation: generation)
    }

    /// Unregister-then-register is what reloaded an unloaded job by hand, and
    /// macOS keeps the approval across it, so it does not prompt.
    private func reregister(generation: Int) async {
        do {
            try await service.unregister()
        } catch {
            Log.app.notice("Sleep helper unregister before re-register: \(error.localizedDescription, privacy: .public)")
        }
        guard generation == self.generation else { return }
        do {
            try service.register()
            Log.app.notice("Re-registered the sleep helper")
        } catch {
            Log.app.error("Sleep helper re-register failed: \(error.localizedDescription, privacy: .public)")
        }
        readStatus()
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

    // MARK: - Version

    private var isHoldActive: Bool { wantsEngaged || isEngaged || engagePending }

    /// The launch sweep's init call and every `.enabled` read land here, so
    /// the first time the helper is reachable is when this runs.
    private func checkVersionIfNeeded() {
        guard Self.changesRegistrationOnItsOwn, !isRecovering, versionPolicy.beginCheck() else { return }
        let generation = generation
        Task {
            let answer = await SleepHelperVersionQuery.ask(timeout: 5) { Self.makeConnection() }
            guard generation == self.generation else {
                versionPolicy.abandonCheck()
                return
            }
            let appBuild = versionPolicy.appBuild
            switch versionPolicy.record(answer, holdActive: isHoldActive) {
            case .current:
                Log.app.notice("Sleep helper version: \(String(describing: answer), privacy: .public), app build \(appBuild, privacy: .public)")
            case .reinstall:
                Log.app.notice("Sleep helper is outdated (\(String(describing: answer), privacy: .public), app build \(appBuild, privacy: .public)); reinstalling")
                reinstallForVersion()
            case .deferReinstall:
                Log.app.notice("Sleep helper is outdated (\(String(describing: answer), privacy: .public), app build \(appBuild, privacy: .public)); reinstalling once the hold is released")
            case .stillOutdated:
                Log.app.error("Sleep helper is still outdated after reinstalling (\(String(describing: answer), privacy: .public), app build \(appBuild, privacy: .public)); leaving it")
            case .retryLater:
                Log.app.notice("Sleep helper did not answer the version check; asking again later")
            case .giveUp:
                Log.app.error("Sleep helper did not answer the version check; not asking again this launch")
            }
        }
    }

    /// Waits out the helper's deferred sleep request after a lid-closed
    /// release, which a reinstall would otherwise kill.
    private func scheduleDeferredReinstall() {
        stopDeferredReinstall()
        deferredReinstallTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.deferredReinstallTimer = nil
                guard !self.isRecovering,
                      self.versionPolicy.claimDeferredReinstall(holdActive: self.isHoldActive)
                else { return }
                Log.app.notice("Hold released; reinstalling the outdated sleep helper")
                self.reinstallForVersion()
            }
        }
    }

    private func stopDeferredReinstall() {
        deferredReinstallTimer?.invalidate()
        deferredReinstallTimer = nil
    }

    private func reinstallForVersion() {
        resetRecovery()
        isRecovering = true
        let generation = generation
        Task {
            await reregister(generation: generation)
            guard generation == self.generation else { return }
            isRecovering = false
            readStatus()
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

    private func proxy(onError: (() -> Void)? = nil) -> (any SleepHelperProtocol)? {
        if connection == nil {
            let connection = Self.makeConnection()
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

    private nonisolated static func makeConnection() -> NSXPCConnection {
        let connection = NSXPCConnection(machServiceName: sleepHelperServiceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: SleepHelperProtocol.self)
        connection.setCodeSigningRequirement(helperRequirement)
        return connection
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
        readStatus()
    }

    // MARK: - Approval

    /// `SMAppService.status` is not observable, and the approval happens in
    /// another app, so poll while it is the only thing left to wait for.
    private func startApprovalPoll() {
        guard approvalPoll == nil else { return }
        approvalPoll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.readStatus() }
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
