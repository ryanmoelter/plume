import Testing
import Foundation
@testable import Plume

/// Covers which tabs count as a reason to keep the Mac awake, how the mode
/// and power source fold in, and that the assertion is neither churned nor
/// leaked.
@MainActor
struct KeepAwakeTests {
    /// Records every application, so a test can assert what happened over a
    /// sequence rather than only where it ended up.
    private final class FakeSleepAssertion: SleepAssertion {
        private(set) var held: SleepAssertionRequest?
        private(set) var applications: [SleepAssertionRequest?] = []

        func apply(_ request: SleepAssertionRequest?) {
            guard request != held else { return }
            applications.append(request)
            held = request
        }
    }

    /// Accepts every apply but never actually holds — stands in for the OS
    /// declining an assertion under load.
    private final class RefusingSleepAssertion: SleepAssertion {
        let held: SleepAssertionRequest? = nil
        func apply(_ request: SleepAssertionRequest?) {}
    }

    private func makeSettings() -> AppSettings {
        AppSettings(defaults: UserDefaults(suiteName: "KeepAwakeTests-\(UUID().uuidString)")!)
    }

    private func makeCoordinator(
        engine: StatusEngine,
        sessions: HeadlessSessionManager? = nil,
        settings: AppSettings? = nil,
        assertion: FakeSleepAssertion? = nil,
        powerSource: KeepAwakeCoordinator.PowerSource = .ac
    ) -> (KeepAwakeCoordinator, FakeSleepAssertion, AppSettings) {
        let settings = settings ?? makeSettings()
        let assertion = assertion ?? FakeSleepAssertion()
        let coordinator = KeepAwakeCoordinator(
            engine: engine,
            sessions: sessions ?? HeadlessSessionManager(),
            settings: settings,
            assertion: assertion,
            powerSource: { powerSource }
        )
        return (coordinator, assertion, settings)
    }

    // MARK: - Which tabs are a reason

    /// Asserted over every case so a new `TaskStatus` fails here rather than
    /// silently landing on one side or the other.
    @Test func onlyWorkingKeepsTheMacAwakeWithoutRemoteControl() {
        for status in TaskStatus.allCases {
            let tabID = UUID()
            let reasons = KeepAwakeCoordinator.deriveReasons(
                activeTabs: [(taskID: UUID(), tabID: tabID, status: status)],
                remoteControlledTabs: []
            )
            #expect(reasons.count == (status == .working ? 1 : 0), "\(status)")
        }
    }

    /// A waiting tab is a reason only when someone can answer it from away.
    @Test func waitingCountsOnlyWhileRemotelyControlled() {
        let taskID = UUID()
        let tabID = UUID()

        for status in TaskStatus.allCases where status.wantsAttention {
            let alone = KeepAwakeCoordinator.deriveReasons(
                activeTabs: [(taskID: taskID, tabID: tabID, status: status)],
                remoteControlledTabs: []
            )
            #expect(alone.isEmpty, "\(status) without remote control")

            let remote = KeepAwakeCoordinator.deriveReasons(
                activeTabs: [(taskID: taskID, tabID: tabID, status: status)],
                remoteControlledTabs: [(taskID: taskID, tabID: tabID)]
            )
            #expect(remote.contains { $0.kind == .working(status) }, "\(status) with remote control")
        }
    }

    @Test func aWorkingRemotelyControlledTabIsTwoReasons() {
        let taskID = UUID()
        let tabID = UUID()
        let reasons = KeepAwakeCoordinator.deriveReasons(
            activeTabs: [(taskID: taskID, tabID: tabID, status: .working)],
            remoteControlledTabs: [(taskID: taskID, tabID: tabID)]
        )
        #expect(reasons.count == 2)
        #expect(reasons.contains { $0.kind == .working(.working) })
        #expect(reasons.contains { $0.kind == .remoteControl })
    }

    @Test func remoteControlAloneKeepsTheMacAwake() {
        let reasons = KeepAwakeCoordinator.deriveReasons(
            activeTabs: [],
            remoteControlledTabs: [(taskID: UUID(), tabID: UUID())]
        )
        #expect(reasons.map(\.kind) == [.remoteControl])
    }

    // MARK: - Mode and power

    @Test func neverNeverHolds() {
        let reasons = KeepAwakeCoordinator.deriveReasons(
            activeTabs: [(taskID: UUID(), tabID: UUID(), status: .working)],
            remoteControlledTabs: []
        )
        #expect(KeepAwakeCoordinator.decide(
            reasons: reasons, mode: .never, powerSource: .ac, allowsBattery: true
        ) == .off(nil))
    }

    @Test func alwaysHoldsWithNoReasons() {
        let decision = KeepAwakeCoordinator.decide(
            reasons: [], mode: .always, powerSource: .ac, allowsBattery: false
        )
        guard case .hold(let request) = decision else {
            Issue.record("expected a hold, got \(decision)")
            return
        }
        #expect(request.reason.contains("Always"))
    }

    @Test func autoHoldsOnlyWithAReason() {
        #expect(KeepAwakeCoordinator.decide(
            reasons: [], mode: .auto, powerSource: .ac, allowsBattery: false
        ) == .off(nil))

        let working = [KeepAwakeReason(taskID: UUID(), tabID: UUID(), kind: .working(.working))]
        guard case .hold = KeepAwakeCoordinator.decide(
            reasons: working, mode: .auto, powerSource: .ac, allowsBattery: false
        ) else {
            Issue.record("expected a hold")
            return
        }
    }

    @Test func batteryHoldsOnlyWhenAllowed() {
        let working = [KeepAwakeReason(taskID: UUID(), tabID: UUID(), kind: .working(.working))]
        #expect(KeepAwakeCoordinator.decide(
            reasons: working, mode: .auto, powerSource: .battery, allowsBattery: false
        ) == .off(.battery))
        guard case .hold = KeepAwakeCoordinator.decide(
            reasons: working, mode: .auto, powerSource: .battery, allowsBattery: true
        ) else {
            Issue.record("expected a hold")
            return
        }
        #expect(KeepAwakeCoordinator.decide(
            reasons: [], mode: .always, powerSource: .battery, allowsBattery: false
        ) == .off(.battery))
    }

    /// The network type is what Apple documents for a host serving remote
    /// clients, and it only applies on AC.
    @Test func remoteControlPicksTheNetworkAssertionOnlyOnAC() {
        let remote = [KeepAwakeReason(taskID: UUID(), tabID: UUID(), kind: .remoteControl)]
        #expect(type(for: remote, mode: .auto, powerSource: .ac, allowsBattery: true) == .networkClientActive)
        #expect(type(for: remote, mode: .auto, powerSource: .battery, allowsBattery: true) == .preventIdleSystemSleep)

        let working = [KeepAwakeReason(taskID: UUID(), tabID: UUID(), kind: .working(.working))]
        #expect(type(for: working, mode: .auto, powerSource: .ac, allowsBattery: true) == .preventIdleSystemSleep)
    }

    private func type(
        for reasons: [KeepAwakeReason],
        mode: KeepAwakeMode,
        powerSource: KeepAwakeCoordinator.PowerSource,
        allowsBattery: Bool
    ) -> SleepAssertionType? {
        guard case .hold(let request) = KeepAwakeCoordinator.decide(
            reasons: reasons, mode: mode, powerSource: powerSource, allowsBattery: allowsBattery
        ) else { return nil }
        return request.type
    }

    @Test func theReasonFitsWhatIOKitAccepts() {
        let many = (0..<50).map {
            KeepAwakeReason(taskID: UUID(), tabID: UUID(), kind: .working($0.isMultiple(of: 2) ? .working : .permissionNeeded))
        }
        guard case .hold(let request) = KeepAwakeCoordinator.decide(
            reasons: many, mode: .auto, powerSource: .ac, allowsBattery: false
        ) else {
            Issue.record("expected a hold")
            return
        }
        #expect(request.reason.count <= SleepAssertionRequest.reasonLimit)
    }

    // MARK: - Off reason

    @Test func offReasonIsBatteryWhenBatteryBlocksAWantedHold() {
        let engine = StatusEngine()
        let (coordinator, _, settings) = makeCoordinator(engine: engine, powerSource: .battery)
        settings.keepsAwakeOnBattery = false

        engine.setStatus(.working, taskID: UUID(), tabID: UUID())
        coordinator.refresh()

        #expect(coordinator.isHolding == false)
        #expect(coordinator.offReason == .battery)
    }

    @Test func offReasonIsNilOnBatteryWhenAllowed() {
        let engine = StatusEngine()
        let (coordinator, _, settings) = makeCoordinator(engine: engine, powerSource: .battery)
        settings.keepsAwakeOnBattery = true

        engine.setStatus(.working, taskID: UUID(), tabID: UUID())
        coordinator.refresh()

        #expect(coordinator.isHolding)
        #expect(coordinator.offReason == nil)
    }

    @Test func offReasonIsNilWithNothingWantingAHold() {
        let engine = StatusEngine()
        let (coordinator, _, _) = makeCoordinator(engine: engine, powerSource: .battery)
        coordinator.refresh()

        #expect(coordinator.offReason == nil)
    }

    /// Never mode declines the hold on purpose, which is not the system
    /// refusing anything.
    @Test func offReasonIsNilInNeverModeEvenWithReasons() {
        let engine = StatusEngine()
        let (coordinator, _, settings) = makeCoordinator(engine: engine)
        settings.keepAwakeMode = .never

        engine.setStatus(.working, taskID: UUID(), tabID: UUID())
        coordinator.refresh()

        #expect(coordinator.isHolding == false)
        #expect(coordinator.offReason == nil)
    }

    @Test func offReasonIsRefusedWhenTheAssertionIsRequestedButNotGranted() {
        let engine = StatusEngine()
        let coordinator = KeepAwakeCoordinator(
            engine: engine,
            sessions: HeadlessSessionManager(),
            settings: makeSettings(),
            assertion: RefusingSleepAssertion(),
            powerSource: { .ac }
        )

        engine.setStatus(.working, taskID: UUID(), tabID: UUID())
        coordinator.refresh()

        #expect(coordinator.isHolding == false)
        #expect(coordinator.offReason == .refused)
    }

    @Test func theSidebarTallyCountsWhatIsHolding() {
        let engine = StatusEngine()
        let (coordinator, _, _) = makeCoordinator(engine: engine)
        #expect(coordinator.tally == (working: 0, remotelyControlled: false))

        let taskID = UUID()
        engine.setStatus(.working, taskID: taskID, tabID: UUID())
        coordinator.refresh()
        #expect(coordinator.tally == (working: 1, remotelyControlled: false))

        engine.setStatus(.working, taskID: taskID, tabID: UUID())
        coordinator.refresh()
        #expect(coordinator.tally == (working: 2, remotelyControlled: false))
    }

    // MARK: - The assertion itself

    @Test func statusEventsDoNotChurnTheAssertion() {
        let engine = StatusEngine()
        let (coordinator, assertion, _) = makeCoordinator(engine: engine)
        let taskID = UUID()
        let tabID = UUID()

        for _ in 0..<10 {
            engine.setStatus(.working, taskID: taskID, tabID: tabID)
            coordinator.refresh()
        }
        #expect(assertion.applications.count == 1)
        #expect(assertion.held != nil)
    }

    @Test func theAssertionIsReleasedWhenWorkStops() {
        let engine = StatusEngine()
        let (coordinator, assertion, _) = makeCoordinator(engine: engine)
        let taskID = UUID()
        let tabID = UUID()

        engine.setStatus(.working, taskID: taskID, tabID: tabID)
        coordinator.refresh()
        #expect(assertion.held != nil)

        engine.setStatus(.awaitingReply, taskID: taskID, tabID: tabID)
        coordinator.refresh()
        #expect(assertion.held == nil)
        #expect(assertion.applications.last == .some(nil))
    }

    @Test func forgettingATabReleasesTheAssertion() {
        let engine = StatusEngine()
        let (coordinator, assertion, _) = makeCoordinator(engine: engine)
        let taskID = UUID()
        let tabID = UUID()

        engine.setStatus(.working, taskID: taskID, tabID: tabID)
        coordinator.refresh()
        #expect(assertion.held != nil)

        engine.forget(tabID: tabID, taskID: taskID)
        coordinator.refresh()
        #expect(assertion.held == nil)
    }

    @Test func switchingToNeverReleasesTheAssertion() {
        let engine = StatusEngine()
        let (coordinator, assertion, settings) = makeCoordinator(engine: engine)
        engine.setStatus(.working, taskID: UUID(), tabID: UUID())
        coordinator.refresh()
        #expect(assertion.held != nil)

        settings.keepAwakeMode = .never
        coordinator.refresh()
        #expect(assertion.held == nil)
    }

    /// `isHolding` drives the footer icon, and switching to Always with
    /// nothing working moves it without moving `reasons` — so it has to be
    /// observable storage of its own, not a read through to the assertion.
    @Test func switchingToAlwaysWithNoReasonsStartsHolding() {
        let (coordinator, _, settings) = makeCoordinator(engine: StatusEngine())
        coordinator.refresh()
        #expect(coordinator.isHolding == false)
        #expect(coordinator.reasons.isEmpty)

        settings.keepAwakeMode = .always
        coordinator.refresh()
        #expect(coordinator.isHolding)
        #expect(coordinator.reasons.isEmpty)
    }

    @Test func terminationReleasesTheAssertion() {
        let engine = StatusEngine()
        let (coordinator, assertion, _) = makeCoordinator(engine: engine)
        engine.setStatus(.working, taskID: UUID(), tabID: UUID())
        coordinator.refresh()
        #expect(assertion.held != nil)

        coordinator.releaseForTermination()
        #expect(assertion.held == nil)
        #expect(coordinator.reasons.isEmpty)
    }

    // MARK: - StatusEngine's enumeration

    @Test func activeTabsListsWorkingAndWaitingTabs() {
        let engine = StatusEngine()
        let taskID = UUID()
        let working = UUID()
        let waiting = UUID()
        let settled = UUID()

        engine.setStatus(.working, taskID: taskID, tabID: working)
        engine.setStatus(.permissionNeeded, taskID: taskID, tabID: waiting)
        engine.setStatus(.awaitingReply, taskID: taskID, tabID: settled)

        let ids = Set(engine.activeTabs.map(\.tabID))
        #expect(ids == [working, waiting])
    }

    /// A restored tab has no process behind it, so its transcript's "working"
    /// is history, not a reason to stay awake.
    @Test func aRestoredTabIsNotActive() {
        let engine = StatusEngine()
        let taskID = UUID()
        let tabID = UUID()
        engine.restore(tabID: tabID, taskID: taskID)
        engine.setSubagentActivity(tabID: tabID, working: true)

        #expect(engine.activeTabs.isEmpty)
    }

    @Test func workingSubagentsKeepTheMacAwake() {
        let engine = StatusEngine()
        let taskID = UUID()
        let tabID = UUID()
        engine.setStatus(.awaitingReply, taskID: taskID, tabID: tabID)
        engine.setSubagentActivity(tabID: tabID, working: true)

        #expect(engine.activeTabs.map(\.tabID) == [tabID])
    }

    @Test func resetClearsEveryReason() {
        let engine = StatusEngine()
        engine.setStatus(.working, taskID: UUID(), tabID: UUID())
        engine.reset()
        #expect(engine.activeTabs.isEmpty)
    }

    // MARK: - Settings

    @Test func modeDefaultsToAutoAndPersists() {
        let defaults = UserDefaults(suiteName: "KeepAwakeTests-\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        #expect(settings.keepAwakeMode == .auto)
        #expect(settings.keepsAwakeOnBattery == false)

        settings.keepAwakeMode = .always
        settings.keepsAwakeOnBattery = true

        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.keepAwakeMode == .always)
        #expect(reloaded.keepsAwakeOnBattery)
    }

    @Test func anUnrecognizedModeFallsBackToAuto() {
        let defaults = UserDefaults(suiteName: "KeepAwakeTests-\(UUID().uuidString)")!
        defaults.set("sometimes", forKey: "keepAwakeModeRaw")
        #expect(AppSettings(defaults: defaults).keepAwakeMode == .auto)
    }
}

/// Covers what the keep-awake UI tells the user about closing the lid.
///
/// No assertion type survives a lid close, so this guidance is the whole of
/// the lid-close feature — it must never read as a promise Plume can keep.
@MainActor
struct LidCloseGuidanceTests {
    @Test func aLidThatSleepsWarnsAndOffersSettings() {
        let guidance = LidCloseGuidance.resolve(clamshell: .sleeps, mode: .auto)
        #expect(guidance == .sleepsOnLidClose)
        #expect(guidance.summary != nil)
        #expect(guidance.explanation != nil)
        #expect(guidance.offersSystemSettings)
    }

    /// Clamshell mode is the one case where the lid can close and work
    /// continues, so it states that rather than warning.
    @Test func clamshellModeSaysTheLidCanClose() {
        let guidance = LidCloseGuidance.resolve(clamshell: .staysAwake, mode: .auto)
        #expect(guidance == .staysAwakeInClamshell)
        #expect(guidance.summary != nil)
        #expect(guidance.explanation == nil)
        #expect(guidance.offersSystemSettings == false)
    }

    @Test func aMacWithNoLidSaysNothing() {
        let guidance = LidCloseGuidance.resolve(clamshell: .noClamshell, mode: .auto)
        #expect(guidance == .notApplicable)
        #expect(guidance.summary == nil)
        #expect(guidance.offersSystemSettings == false)
    }

    /// Never mode means the user declined Plume's say over sleep, so lid
    /// advice would be noise whatever the hardware reports.
    @Test func neverModeSuppressesLidAdvice() {
        for clamshell in [ClamshellSleepBehavior.sleeps, .staysAwake, .noClamshell] {
            let guidance = LidCloseGuidance.resolve(clamshell: clamshell, mode: .never)
            #expect(guidance == .notApplicable, "\(clamshell)")
            #expect(guidance.summary == nil, "\(clamshell)")
        }
    }

    @Test func alwaysModeStillWarnsAboutTheLid() {
        #expect(LidCloseGuidance.resolve(clamshell: .sleeps, mode: .always) == .sleepsOnLidClose)
    }

    /// The guidance must never claim the Mac will keep working through a lid
    /// close, which is the promise macOS cannot deliver.
    @Test func theWarningNeverPromisesTheMacStaysAwake() {
        let guidance = LidCloseGuidance.resolve(clamshell: .sleeps, mode: .auto)
        let text = ((guidance.summary ?? "") + " " + (guidance.explanation ?? "")).lowercased()
        #expect(text.contains("sleeps"))
        #expect(!text.contains("plume keeps"))
    }

    @Test func onlyASleepingLidWarns() {
        #expect(ClamshellSleepBehavior.sleeps.warnsAboutLidClose)
        #expect(ClamshellSleepBehavior.staysAwake.warnsAboutLidClose == false)
        #expect(ClamshellSleepBehavior.noClamshell.warnsAboutLidClose == false)
    }
}
