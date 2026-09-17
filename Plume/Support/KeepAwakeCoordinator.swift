import Foundation
import IOKit.ps
import Observation

/// Holds the Mac awake while agents are working or a session is being driven
/// remotely.
///
/// The reason set is *derived* from `StatusEngine` and `HeadlessSessionManager`
/// rather than registered by their call sites. Those two already hold the
/// authoritative state, and a tab stops working from half a dozen places — a
/// counter kept in step by hand would eventually miss one, and a leaked reason
/// means the Mac never sleeps again until Plume relaunches.
@MainActor
@Observable
final class KeepAwakeCoordinator {
    static let shared = KeepAwakeCoordinator()

    /// Why the Mac is awake, in the order the panel lists them.
    private(set) var reasons: [KeepAwakeReason] = []

    /// Whether an assertion is actually held. Not a promise the Mac will stay
    /// awake — the OS may ignore an assertion under battery or thermal load.
    ///
    /// Mirrored into observable storage rather than read through to the
    /// assertion, which is not observable: switching to Always with nothing
    /// working changes this without changing `reasons`, and a view reading
    /// straight through would never redraw.
    private(set) var isHolding = false

    /// Why the Mac isn't held despite `reasons` wanting it, or nil when
    /// nothing wants it or it's already held.
    private(set) var offReason: KeepAwakeOffReason?

    /// Where the lid-closed override stands. Mirrored for the same reason as
    /// `isHolding`: the override's own status changes on XPC replies and
    /// System Settings approvals, which never move `reasons`.
    private(set) var lidOverrideStatus: LidSleepOverrideStatus = .notRegistered

    @ObservationIgnored private let engine: StatusEngine
    @ObservationIgnored private let sessions: HeadlessSessionManager
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let assertion: any SleepAssertion
    @ObservationIgnored private let lidOverride: any LidSleepOverride
    @ObservationIgnored private let powerSource: () -> PowerSource
    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private var powerSourceObserver: CFRunLoopSource?

    enum PowerSource {
        case ac
        case battery
    }

    init(
        engine: StatusEngine = .shared,
        sessions: HeadlessSessionManager = .shared,
        settings: AppSettings = .shared,
        assertion: (any SleepAssertion)? = nil,
        lidOverride: (any LidSleepOverride)? = nil,
        powerSource: @escaping () -> PowerSource = KeepAwakeCoordinator.systemPowerSource
    ) {
        self.engine = engine
        self.sessions = sessions
        self.settings = settings
        self.assertion = assertion ?? IOKitSleepAssertion()
        self.lidOverride = lidOverride ?? DaemonLidSleepOverride()
        self.powerSource = powerSource
    }

    // MARK: - Lifecycle

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        refresh()
        observe()
        watchPowerSource()
    }

    /// Power source is not observable state, so unplugging the Mac has to be
    /// heard from IOKit or a running turn would keep its assertion until some
    /// unrelated input happened to change.
    private func watchPowerSource() {
        let callback: IOPowerSourceCallbackType = { context in
            guard let context else { return }
            let coordinator = Unmanaged<KeepAwakeCoordinator>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in coordinator.refresh() }
        }
        guard let source = IOPSNotificationCreateRunLoopSource(
            callback,
            Unmanaged.passUnretained(self).toOpaque()
        )?.takeRetainedValue() else { return }
        powerSourceObserver = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
    }

    func releaseForTermination() {
        assertion.apply(nil)
        lidOverride.apply(false)
        reasons = []
        isHolding = false
        offReason = nil
    }

    /// For the panel opening: registration state lives in launchd and can
    /// change while Plume is in the background.
    func refreshLidOverride() {
        lidOverride.refreshStatus()
        mirrorLidOverrideStatus()
    }

    /// Recomputes the reason set and applies it. Idempotent, so redundant
    /// triggers cost nothing.
    func refresh() {
        let derived = Self.deriveReasons(
            activeTabs: engine.activeTabs,
            remoteControlledTabs: sessions.remoteControlledTabs
        )
        if derived != reasons {
            reasons = derived
        }
        let decision = Self.decide(
            reasons: derived,
            mode: settings.keepAwakeMode,
            powerSource: powerSource(),
            allowsBattery: settings.keepsAwakeOnBattery
        )
        switch decision {
        case .hold(let request):
            assertion.apply(request)
        case .off:
            assertion.apply(nil)
        }
        if isHolding != (assertion.held != nil) {
            isHolding = assertion.held != nil
        }

        let derivedOffReason: KeepAwakeOffReason? = {
            switch decision {
            case .off(let reason): return reason
            case .hold: return isHolding ? nil : .refused
            }
        }()
        if offReason != derivedOffReason {
            offReason = derivedOffReason
        }

        // Registration prompts for approval, so it waits for the user to turn
        // the setting on rather than happening at launch.
        if settings.keepsAwakeWithLidClosed {
            lidOverride.ensureRegistered()
        }
        lidOverride.apply(Self.decideLidOverride(
            decision: decision,
            wantsLidClosed: settings.keepsAwakeWithLidClosed
        ))
        mirrorLidOverrideStatus()
    }

    private func mirrorLidOverrideStatus() {
        if lidOverrideStatus != lidOverride.status {
            lidOverrideStatus = lidOverride.status
        }
    }

    /// Re-arms itself on every change, because `withObservationTracking` fires
    /// its handler once. Only inputs are read inside the tracked closure:
    /// touching `reasons` there would make the write in `refresh` retrigger it
    /// forever.
    private func observe() {
        withObservationTracking {
            _ = engine.activeTabs
            _ = sessions.remoteControlledTabs
            _ = settings.keepAwakeMode
            _ = settings.keepsAwakeOnBattery
            _ = settings.keepsAwakeWithLidClosed
            _ = lidOverride.status
        } onChange: { [weak self] in
            // The handler runs before the new value lands, so read it on the
            // next turn instead of the value being replaced.
            Task { @MainActor [weak self] in
                self?.refresh()
                self?.observe()
            }
        }
    }

    // MARK: - Deciding

    /// A tab is a reason when it is working, or when it is remotely
    /// controlled, or when it wants the user *and* is remotely controlled.
    ///
    /// A tab waiting for an answer with no Remote Control is not a reason: no
    /// work is happening, and nobody is coming to answer it.
    static func deriveReasons(
        activeTabs: [(taskID: UUID, tabID: UUID, status: TaskStatus)],
        remoteControlledTabs: [(taskID: UUID, tabID: UUID)]
    ) -> [KeepAwakeReason] {
        let remoteTabIDs = Set(remoteControlledTabs.map(\.tabID))

        let working = activeTabs
            .filter { $0.status == .working || remoteTabIDs.contains($0.tabID) }
            .map { KeepAwakeReason(taskID: $0.taskID, tabID: $0.tabID, kind: .working($0.status)) }

        let remote = remoteControlledTabs
            .map { KeepAwakeReason(taskID: $0.taskID, tabID: $0.tabID, kind: .remoteControl) }

        // Dictionary order is arbitrary; sorting keeps the panel from
        // reshuffling every time an unrelated tab changes status.
        return (working + remote).sorted { $0.id < $1.id }
    }

    /// Whether to hold the Mac awake, or why not.
    enum Decision: Equatable {
        case hold(SleepAssertionRequest)
        /// Battery blocking is worth naming; the mode simply not wanting a
        /// hold isn't, so it carries no reason.
        case off(KeepAwakeOffReason?)
    }

    static func decide(
        reasons: [KeepAwakeReason],
        mode: KeepAwakeMode,
        powerSource: PowerSource,
        allowsBattery: Bool
    ) -> Decision {
        switch mode {
        case .never:
            return .off(nil)
        case .auto where reasons.isEmpty:
            return .off(nil)
        case .auto, .always:
            break
        }
        guard powerSource == .ac || allowsBattery else { return .off(.battery) }

        let servesRemoteClients = reasons.contains { $0.kind == .remoteControl }
        return .hold(SleepAssertionRequest(
            // Apple documents the network type for a host serving remote
            // clients, and it holds through dark wake. It is AC-only, so idle
            // sleep prevention covers everything else.
            type: servesRemoteClients && powerSource == .ac ? .networkClientActive : .preventIdleSystemSleep,
            reason: summary(reasons: reasons, mode: mode)
        ))
    }

    /// The lid override rides on a hold and never replaces one. So whatever
    /// blocks the hold — Never mode, nothing working, battery not allowed —
    /// blocks the override too, and a Mac that is not being held awake is
    /// never left unable to sleep.
    static func decideLidOverride(decision: Decision, wantsLidClosed: Bool) -> Bool {
        guard wantsLidClosed else { return false }
        if case .hold = decision { return true }
        return false
    }

    /// How many tabs are working, and whether any is remotely controlled, for
    /// the sidebar row — where the whole reason list would not fit.
    var tally: (working: Int, remotelyControlled: Bool) {
        (
            working: reasons.count { if case .working = $0.kind { true } else { false } },
            remotelyControlled: reasons.contains { $0.kind == .remoteControl }
        )
    }

    /// What the user reads in `pmset -g assertions` and the battery menu.
    /// ASCII only: that listing mangles anything else.
    static func summary(reasons: [KeepAwakeReason], mode: KeepAwakeMode) -> String {
        guard mode != .always || !reasons.isEmpty else {
            return "Plume: Keep Awake is set to Always"
        }
        let working = reasons.count { if case .working = $0.kind { true } else { false } }
        let remote = reasons.count { $0.kind == .remoteControl }
        var parts: [String] = []
        if working > 0 {
            parts.append("\(working) \(working == 1 ? "tab" : "tabs") working")
        }
        if remote > 0 {
            parts.append("\(remote) remotely controlled")
        }
        return "Plume: " + parts.joined(separator: ", ")
    }

    nonisolated static func systemPowerSource() -> PowerSource {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return .ac }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?
                .takeUnretainedValue() as? [String: Any],
                let state = description[kIOPSPowerSourceStateKey] as? String
            else { continue }
            if state == kIOPSBatteryPowerValue { return .battery }
        }
        // A desktop reports no battery source at all, which is AC.
        return .ac
    }
}
