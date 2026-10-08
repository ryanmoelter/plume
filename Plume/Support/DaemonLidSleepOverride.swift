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
    @ObservationIgnored private lazy var registrar = ServiceRegistrar(service: service)
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
        appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
        appBundlePath: Bundle.main.bundlePath
    )
    @ObservationIgnored private var deferredCheckTimer: Timer?
    @ObservationIgnored private var lastRelease: Date?
    @ObservationIgnored private var lastReadingSawOverride = false

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

    @ObservationIgnored private let isInert = !SleepHelperRegistrationGate.allowsRegistrationInThisProcess

    init() {
        if isInert {
            status = .unavailable(SleepHelperRegistrationGate.disabledReason)
            return
        }
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
        guard !isInert else { return }
        readStatus()
        if status == .unresponsive, !wantsEngaged { checkResponsive() }
    }

    func ensureRegistered() {
        guard !isInert else { return }
        // A re-register passes through notRegistered and owns the registration until it ends.
        guard status == .notRegistered, !isRecovering else { return }
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
        guard !isInert, status != .notRegistered else { return }
        apply(false)
        stopDeferredCheck()
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
        guard !isInert else { return }
        versionPolicy.recordManualReinstall()
        stopDeferredCheck()
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
        guard !isInert else { return }
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
        if versionPolicy.isReinstallDeferred { scheduleDeferredCheck(after: Self.releaseSettleDelay) }
        guard isEngaged || engagePending else { return }
        isEngaged = false
        engagePending = false
        let sleepIfLidClosed = !ExternalDisplay.isConnected
        lastRelease = Date()
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
        let wasRecovering = isRecovering
        isRecovering = true
        await reregister(generation: generation)
        guard generation == self.generation, !wasRecovering else { return }
        isRecovering = false
        readStatus()
    }

    /// A failure leaves the panel offering Install or Reinstall, never "Installed".
    private func reregister(generation: Int) async {
        let outcome = await SleepHelperReregistration.run(
            registrar,
            isCurrent: { generation == self.generation },
            log: { Log.app.notice("\($0, privacy: .public)") }
        )
        switch outcome {
        case .loaded(let attempts):
            Log.app.notice("Re-registered the sleep helper (register attempts after unregistering: \(attempts))")
        case .needsApproval:
            Log.app.notice("Re-registering the sleep helper needs approval in Login Items")
        case .failed(let reason):
            Log.app.error("Sleep helper re-register failed: \(reason, privacy: .public)")
            // A notRegistered status already offers Install.
            if service.status == .enabled { retryPolicy.markUnresponsive() }
        case .cancelled:
            Log.app.notice("Sleep helper re-register superseded")
            return
        }
        readStatus()
    }

    /// Reports loaded when `launchctl` itself cannot run, so nothing is
    /// re-registered on a guess.
    private nonisolated static func isHelperLoaded() async -> Bool {
        await printHelperJob()?.loaded ?? true
    }

    /// The bundle of the helper launchd is running, for a helper too old to
    /// report it.
    private nonisolated static func runningHelperBundlePath() async -> String? {
        guard let job = await printHelperJob(), job.loaded else { return nil }
        let parsed = SleepHelperVersionQuery.helperExecutable(inLaunchctlPrint: job.output)
        let executable = parsed.executable
        return SleepHelperVersionQuery.legacyHelperBundle(
            job: parsed,
            executable: executable,
            executableExists: executable.map { FileManager.default.fileExists(atPath: $0.path) } ?? false,
            appBundlePath: Bundle.main.bundlePath,
            appBundleIdentifier: Bundle.main.bundleIdentifier
        )
    }

    /// `launchctl print` needs no root. Nil when it cannot run.
    private nonisolated static func printHelperJob() async -> (loaded: Bool, output: String)? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                let stdout = Pipe()
                process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
                process.arguments = ["print", "system/\(sleepHelperServiceName)"]
                process.standardOutput = stdout
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                    let data = stdout.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    continuation.resume(returning: (
                        process.terminationStatus == 0,
                        String(decoding: data, as: UTF8.self)
                    ))
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private final class ServiceRegistrar: SleepHelperRegistrar {
        let service: SMAppService

        init(service: SMAppService) {
            self.service = service
        }

        var status: SleepHelperServiceStatus {
            switch service.status {
            case .notRegistered, .notFound: .notRegistered
            case .requiresApproval: .requiresApproval
            case .enabled: .enabled
            @unknown default: .unknown
            }
        }

        func register() -> SleepHelperRegisterResult {
            do {
                try service.register()
                return .registered
            } catch let error as NSError {
                let denied = error.code == Int(EPERM) || error.code == kSMErrorLaunchDeniedByUser
                let reason = "\(error.localizedDescription) (\(error.domain) \(error.code))"
                return denied ? .denied(reason) : .failed(reason)
            }
        }

        func unregister() async -> String? {
            do {
                try await service.unregister()
                return nil
            } catch {
                return error.localizedDescription
            }
        }

        func isLoaded() async -> Bool? {
            await DaemonLidSleepOverride.printHelperJob()?.loaded
        }

        func wait(_ seconds: TimeInterval) async {
            try? await Task.sleep(for: .seconds(seconds))
        }
    }

    // MARK: - Version

    private var isLocalHoldActive: Bool { wantsEngaged || isEngaged || engagePending }

    /// The helper requests a lid-closed sleep about a second after a release,
    /// and a reinstall inside that window would kill the request.
    private var releasedRecently: Bool {
        guard let lastRelease else { return false }
        return Date().timeIntervalSince(lastRelease) < Self.releaseSettleDelay
    }

    private static let releaseSettleDelay: TimeInterval = 3
    /// How often to look again while another install holds the override.
    private static let remoteHoldRecheckDelay: TimeInterval = 60

    /// The launch sweep's init call and every `.enabled` read land here, so
    /// the first time the helper is reachable is when this runs.
    private func checkVersionIfNeeded() {
        guard Self.changesRegistrationOnItsOwn, !isRecovering, versionPolicy.beginCheck() else { return }
        let generation = generation
        Task {
            let reading = await SleepHelperVersionQuery.ask(
                timeout: 5,
                connect: { Self.makeConnection() },
                legacyBundlePath: { await Self.runningHelperBundlePath() }
            )
            guard generation == self.generation else {
                versionPolicy.abandonCheck()
                return
            }
            // Another install's hold counts too: launchd has one job for all.
            // A hold seen last time and gone now may have been released within
            // the helper's sleep-request window, so wait that out once too.
            let holdActive = isLocalHoldActive || releasedRecently || reading.overrideEngaged || lastReadingSawOverride
            lastReadingSawOverride = reading.overrideEngaged
            let described = "\(reading.answer) at \(reading.helperBundlePath ?? "an unknown bundle"), "
                + "app build \(versionPolicy.appBuild) at \(versionPolicy.appBundlePath)"
            switch versionPolicy.record(reading.answer, helperBundlePath: reading.helperBundlePath, holdActive: holdActive) {
            case .current:
                Log.app.notice("Sleep helper version: \(described, privacy: .public)")
            case .reinstall:
                Log.app.notice("Sleep helper is outdated (\(described, privacy: .public)); reinstalling")
                reinstallForVersion()
            case .deferReinstall:
                Log.app.notice("Sleep helper is outdated (\(described, privacy: .public)); reinstalling once no hold needs it")
                // A local hold schedules the recheck when it is released.
                if !isLocalHoldActive {
                    scheduleDeferredCheck(after: reading.overrideEngaged ? Self.remoteHoldRecheckDelay : Self.releaseSettleDelay)
                }
            case .notOwnBundle:
                Log.app.notice("Sleep helper is outdated (\(described, privacy: .public)), but another install registered it; leaving it")
            case .stillOutdated:
                Log.app.error("Sleep helper is still outdated after reinstalling (\(described, privacy: .public)); leaving it")
            case .retryLater:
                Log.app.notice("Sleep helper did not answer the version check; asking again later")
            case .giveUp:
                Log.app.error("Sleep helper did not answer the version check; not asking again this launch")
            }
        }
    }

    private func scheduleDeferredCheck(after delay: TimeInterval) {
        stopDeferredCheck()
        deferredCheckTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.deferredCheckTimer = nil
                self.versionPolicy.resumeDeferred()
                self.readStatus()
            }
        }
    }

    private func stopDeferredCheck() {
        deferredCheckTimer?.invalidate()
        deferredCheckTimer = nil
    }

    private func reinstallForVersion() {
        guard service.status == .enabled else { return }
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
