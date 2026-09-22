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

    /// The latest power reading. Mirrored into observable storage the same
    /// way `isHolding` is: the footer's battery glyph needs to redraw when
    /// only the percentage moves, and nothing else in `refresh` changes.
    private(set) var powerSnapshot = PowerSnapshot(source: .ac, percent: nil, isCharging: false)

    /// Where the lid-closed override stands. Mirrored for the same reason as
    /// `isHolding`: the override's own status changes on XPC replies and
    /// System Settings approvals, which never move `reasons`.
    private(set) var lidOverrideStatus: LidSleepOverrideStatus = .notRegistered

    /// Whether the lid override is being held back purely by thermal load,
    /// with the plain hold otherwise in effect. Mirrored for the same reason
    /// as `lidOverrideStatus`: a thermal state change moves this without
    /// moving `reasons`.
    private(set) var lidOverridePausedForHeat = false

    @ObservationIgnored private let engine: StatusEngine
    @ObservationIgnored private let sessions: HeadlessSessionManager
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let assertion: any SleepAssertion
    @ObservationIgnored private let powerSnapshotReader: () -> PowerSnapshot
    @ObservationIgnored private let lidOverride: any LidSleepOverride
    @ObservationIgnored private let thermal: any ThermalStateSource
    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private var powerSourceObserver: CFRunLoopSource?

    enum PowerSource {
        case ac
        case battery
    }

    struct PowerSnapshot: Equatable, Sendable {
        var source: PowerSource
        var percent: Int?
        var isCharging: Bool
    }

    init(
        engine: StatusEngine = .shared,
        sessions: HeadlessSessionManager = .shared,
        settings: AppSettings = .shared,
        assertion: (any SleepAssertion)? = nil,
        powerSnapshot: @escaping () -> PowerSnapshot = KeepAwakeCoordinator.systemPowerSnapshot,
        lidOverride: (any LidSleepOverride)? = nil,
        thermal: (any ThermalStateSource)? = nil
    ) {
        self.engine = engine
        self.sessions = sessions
        self.settings = settings
        self.assertion = assertion ?? IOKitSleepAssertion()
        self.powerSnapshotReader = powerSnapshot
        self.lidOverride = lidOverride ?? DaemonLidSleepOverride()
        self.thermal = thermal ?? ThermalStateMonitor()
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
        lidOverridePausedForHeat = false
    }

    /// For the panel opening: registration state lives in launchd and can
    /// change while Plume is in the background.
    func refreshLidOverride() {
        lidOverride.refreshStatus()
        mirrorLidOverrideStatus()
    }

    /// Registration prompts for approval, so it only ever runs from the
    /// install button, never from a setting or at launch.
    func installLidHelper() {
        lidOverride.ensureRegistered()
        mirrorLidOverrideStatus()
    }

    /// Removing the helper also turns the setting off, so a later reinstall
    /// is an explicit choice rather than something the next hold does.
    func uninstallLidHelper() {
        settings.keepsAwakeWithLidClosed = false
        lidOverride.unregister()
        mirrorLidOverrideStatus()
    }

    /// Recomputes the reason set and applies it. Idempotent, so redundant
    /// triggers cost nothing.
    func refresh() {
        let derived = Self.deriveReasons(
            activeTabs: engine.activeTabs,
            remoteControlledTabs: sessions.remoteControlledTabs,
            backgroundTaskTabs: engine.backgroundTaskTabs,
            allowsRemoteControl: settings.keepsAwakeForRemoteControl
        )
        if derived != reasons {
            reasons = derived
        }
        let power = powerSnapshotReader()
        if power != powerSnapshot {
            powerSnapshot = power
        }
        let decision = Self.decide(
            reasons: derived,
            mode: settings.keepAwakeMode,
            power: power,
            allowsBattery: settings.keepsAwakeOnBattery,
            batteryCutoffPercent: settings.keepAwakeBatteryCutoffPercent
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

        let cutoff = settings.lidClosedThermalCutoff
        let thermalState = thermal.state
        let wantsLidClosed = settings.keepsAwakeWithLidClosed
        lidOverride.apply(Self.decideLidOverride(
            decision: decision,
            wantsLidClosed: wantsLidClosed,
            thermalState: thermalState,
            cutoff: cutoff
        ))
        mirrorLidOverrideStatus()

        // Paused for heat means the hold would otherwise carry the lid
        // override, and only the thermal cutoff is what's stopping it.
        let wouldOverrideIfCool = Self.decideLidOverride(decision: decision, wantsLidClosed: wantsLidClosed)
        let pausedForHeat = wouldOverrideIfCool && cutoff.isReached(by: thermalState)
        if lidOverridePausedForHeat != pausedForHeat {
            lidOverridePausedForHeat = pausedForHeat
        }
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
            _ = engine.backgroundTaskTabs
            _ = settings.keepAwakeMode
            _ = settings.keepsAwakeOnBattery
            _ = settings.keepAwakeBatteryCutoffPercent
            _ = settings.keepsAwakeWithLidClosed
            _ = settings.keepsAwakeForRemoteControl
            _ = settings.lidClosedThermalCutoff
            _ = lidOverride.status
            _ = thermal.state
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

    /// A tab is a reason when it is working, when it is remotely controlled,
    /// when it wants the user *and* is remotely controlled, or when it has a
    /// background task still running.
    ///
    /// A tab waiting for an answer with no Remote Control is not a reason: no
    /// work is happening, and nobody is coming to answer it.
    ///
    /// `allowsRemoteControl` off drops Remote Control from the reason set
    /// entirely, so a remotely driven tab holds the Mac awake only for work it
    /// is doing itself.
    static func deriveReasons(
        activeTabs: [(taskID: UUID, tabID: UUID, status: TaskStatus)],
        remoteControlledTabs: [(taskID: UUID, tabID: UUID)],
        backgroundTaskTabs: [(taskID: UUID, tabID: UUID, kind: BackgroundTaskTracker.Kind, description: String?)] = [],
        allowsRemoteControl: Bool = true
    ) -> [KeepAwakeReason] {
        let counted = allowsRemoteControl ? remoteControlledTabs : []
        let remoteTabIDs = Set(counted.map(\.tabID))

        let working = activeTabs
            .filter { $0.status == .working || remoteTabIDs.contains($0.tabID) }
            .map { KeepAwakeReason(taskID: $0.taskID, tabID: $0.tabID, kind: .working($0.status)) }

        let remote = counted
            .map { KeepAwakeReason(taskID: $0.taskID, tabID: $0.tabID, kind: .remoteControl) }

        let background = backgroundTaskTabs
            .map {
                KeepAwakeReason(
                    taskID: $0.taskID,
                    tabID: $0.tabID,
                    kind: .backgroundTask($0.kind, description: $0.description)
                )
            }

        // Dictionary order is arbitrary; sorting keeps the panel from
        // reshuffling every time an unrelated tab changes status.
        return (working + remote + background).sorted { $0.id < $1.id }
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
        power: PowerSnapshot,
        allowsBattery: Bool,
        batteryCutoffPercent: Int
    ) -> Decision {
        switch mode {
        case .never:
            return .off(nil)
        case .auto where reasons.isEmpty:
            return .off(nil)
        case .auto, .always:
            break
        }
        guard power.source == .ac || allowsBattery else { return .off(.battery) }

        // Charging ignores the cutoff: the percentage is climbing, not draining.
        if power.source == .battery, !power.isCharging, batteryCutoffPercent > 0,
           let percent = power.percent, percent <= batteryCutoffPercent {
            return .off(.batteryLow(percent))
        }

        let servesRemoteClients = reasons.contains { $0.kind == .remoteControl }
        return .hold(SleepAssertionRequest(
            // Apple documents the network type for a host serving remote
            // clients, and it holds through dark wake. It is AC-only, so idle
            // sleep prevention covers everything else.
            type: servesRemoteClients && power.source == .ac ? .networkClientActive : .preventIdleSystemSleep,
            reason: summary(reasons: reasons, mode: mode)
        ))
    }

    /// The lid override rides on a hold and never replaces one. So whatever
    /// blocks the hold — Never mode, nothing working, battery not allowed or
    /// too low — blocks the override too, and a Mac that is not being held
    /// awake is never left unable to sleep.
    static func decideLidOverride(decision: Decision, wantsLidClosed: Bool) -> Bool {
        decideLidOverride(decision: decision, wantsLidClosed: wantsLidClosed, thermalState: .nominal, cutoff: .serious)
    }

    /// A shut lid can't shed heat as well as an open one, so the override
    /// also releases once `thermalState` reaches `cutoff` — the plain hold
    /// keeps going regardless.
    static func decideLidOverride(
        decision: Decision,
        wantsLidClosed: Bool,
        thermalState: ProcessInfo.ThermalState,
        cutoff: ThermalCutoffLevel
    ) -> Bool {
        guard wantsLidClosed else { return false }
        guard !cutoff.isReached(by: thermalState) else { return false }
        if case .hold = decision { return true }
        return false
    }

    /// How many tabs are working, how many are running something in the
    /// background, and whether any is remotely controlled — for the sidebar
    /// row, where the whole reason list would not fit.
    var tally: (working: Int, backgroundTasks: Int, remotelyControlled: Bool) {
        (
            working: reasons.count { if case .working = $0.kind { true } else { false } },
            backgroundTasks: reasons.count { if case .backgroundTask = $0.kind { true } else { false } },
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
        let background = reasons.count { if case .backgroundTask = $0.kind { true } else { false } }
        let remote = reasons.count { $0.kind == .remoteControl }
        var parts: [String] = []
        if working > 0 {
            parts.append("\(working) \(working == 1 ? "tab" : "tabs") working")
        }
        if background > 0 {
            parts.append("\(background) background \(background == 1 ? "task" : "tasks")")
        }
        if remote > 0 {
            parts.append("\(remote) remotely controlled")
        }
        return "Plume: " + parts.joined(separator: ", ")
    }

    nonisolated static func systemPowerSnapshot() -> PowerSnapshot {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return PowerSnapshot(source: .ac, percent: nil, isCharging: false) }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?
                .takeUnretainedValue() as? [String: Any],
                let state = description[kIOPSPowerSourceStateKey] as? String
            else { continue }
            if state == kIOPSBatteryPowerValue {
                let percent: Int? = {
                    guard let capacity = description[kIOPSCurrentCapacityKey] as? Int,
                          let max = description[kIOPSMaxCapacityKey] as? Int, max > 0
                    else { return nil }
                    return Int((Double(capacity) / Double(max) * 100).rounded())
                }()
                let isCharging = description[kIOPSIsChargingKey] as? Bool ?? false
                return PowerSnapshot(source: .battery, percent: percent, isCharging: isCharging)
            }
        }
        // A desktop reports no battery source at all, which is AC.
        return PowerSnapshot(source: .ac, percent: nil, isCharging: false)
    }
}
