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

    /// The daemon's designated identity, so a process squatting on the Mach
    /// service name cannot impersonate it.
    private static let helperRequirement =
        "anchor apple generic and certificate leaf[subject.OU] = \"\(sleepHelperTeamID)\""
        + " and identifier \"\(sleepHelperServiceName)\""

    init() {
        refreshStatus()
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
        case .notRegistered:
            set(.notRegistered)
            stopApprovalPoll()
        case .notFound:
            set(.unavailable("The sleep helper is missing from this copy of Plume."))
            stopApprovalPoll()
        case .requiresApproval:
            set(.needsApproval)
            startApprovalPoll()
        case .enabled:
            set(isEngaged ? .engaged : .ready)
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
        guard !isEngaged, !engagePending else { return }
        engagePending = true
        proxy()?.setSleepDisabled(true) { [weak self] now, error in
            Task { @MainActor in self?.didEngage(now: now, error: error) }
        }
    }

    private func didEngage(now: Bool, error: String?) {
        engagePending = false
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
        proxy()?.setSleepDisabled(false) { _, _ in }
        Log.app.notice("Lid-closed override released")
        refreshStatus()
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

    private func proxy() -> (any SleepHelperProtocol)? {
        if connection == nil {
            let connection = NSXPCConnection(machServiceName: sleepHelperServiceName, options: .privileged)
            connection.remoteObjectInterface = NSXPCInterface(with: SleepHelperProtocol.self)
            connection.setCodeSigningRequirement(Self.helperRequirement)
            connection.invalidationHandler = { [weak self] in
                Task { @MainActor in self?.connectionDropped() }
            }
            connection.interruptionHandler = { [weak self] in
                Task { @MainActor in self?.connectionDropped() }
            }
            connection.resume()
            self.connection = connection
        }
        return connection?.remoteObjectProxyWithErrorHandler { error in
            Log.app.error("Sleep helper XPC error: \(error.localizedDescription, privacy: .public)")
        } as? any SleepHelperProtocol
    }

    /// The helper clears the override when a connection dies, so anything
    /// still wanted has to be asked for again over a fresh connection.
    private func connectionDropped() {
        connection = nil
        isEngaged = false
        engagePending = false
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
