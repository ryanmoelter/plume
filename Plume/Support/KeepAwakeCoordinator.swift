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
    var isHolding: Bool { assertion.held != nil }

    @ObservationIgnored private let engine: StatusEngine
    @ObservationIgnored private let sessions: HeadlessSessionManager
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let assertion: any SleepAssertion
    @ObservationIgnored private let powerSource: () -> PowerSource
    @ObservationIgnored private var hasStarted = false

    enum PowerSource {
        case ac
        case battery
    }

    init(
        engine: StatusEngine = .shared,
        sessions: HeadlessSessionManager = .shared,
        settings: AppSettings = .shared,
        assertion: (any SleepAssertion)? = nil,
        powerSource: @escaping () -> PowerSource = KeepAwakeCoordinator.systemPowerSource
    ) {
        self.engine = engine
        self.sessions = sessions
        self.settings = settings
        self.assertion = assertion ?? IOKitSleepAssertion()
        self.powerSource = powerSource
    }

    // MARK: - Lifecycle

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        refresh()
        observe()
    }

    func releaseForTermination() {
        assertion.apply(nil)
        reasons = []
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
        assertion.apply(
            Self.decide(
                reasons: derived,
                mode: settings.keepAwakeMode,
                powerSource: powerSource(),
                allowsBattery: settings.keepsAwakeOnBattery
            )
        )
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

    static func decide(
        reasons: [KeepAwakeReason],
        mode: KeepAwakeMode,
        powerSource: PowerSource,
        allowsBattery: Bool
    ) -> SleepAssertionRequest? {
        switch mode {
        case .never:
            return nil
        case .auto where reasons.isEmpty:
            return nil
        case .auto, .always:
            break
        }
        guard powerSource == .ac || allowsBattery else { return nil }

        let servesRemoteClients = reasons.contains { $0.kind == .remoteControl }
        return SleepAssertionRequest(
            // Apple documents the network type for a host serving remote
            // clients, and it holds through dark wake. It is AC-only, so idle
            // sleep prevention covers everything else.
            type: servesRemoteClients && powerSource == .ac ? .networkClientActive : .preventIdleSystemSleep,
            reason: summary(reasons: reasons, mode: mode)
        )
    }

    /// What the user reads in `pmset -g assertions` and the battery menu.
    static func summary(reasons: [KeepAwakeReason], mode: KeepAwakeMode) -> String {
        guard mode != .always || !reasons.isEmpty else {
            return "Plume — Keep Awake is set to Always"
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
        return "Plume — " + parts.joined(separator: ", ")
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
