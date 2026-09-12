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
        ) == nil)
    }

    @Test func alwaysHoldsWithNoReasons() {
        let request = KeepAwakeCoordinator.decide(
            reasons: [], mode: .always, powerSource: .ac, allowsBattery: false
        )
        #expect(request != nil)
        #expect(request?.reason.contains("Always") == true)
    }

    @Test func autoHoldsOnlyWithAReason() {
        #expect(KeepAwakeCoordinator.decide(
            reasons: [], mode: .auto, powerSource: .ac, allowsBattery: false
        ) == nil)

        let working = [KeepAwakeReason(taskID: UUID(), tabID: UUID(), kind: .working(.working))]
        #expect(KeepAwakeCoordinator.decide(
            reasons: working, mode: .auto, powerSource: .ac, allowsBattery: false
        ) != nil)
    }

    @Test func batteryHoldsOnlyWhenAllowed() {
        let working = [KeepAwakeReason(taskID: UUID(), tabID: UUID(), kind: .working(.working))]
        #expect(KeepAwakeCoordinator.decide(
            reasons: working, mode: .auto, powerSource: .battery, allowsBattery: false
        ) == nil)
        #expect(KeepAwakeCoordinator.decide(
            reasons: working, mode: .auto, powerSource: .battery, allowsBattery: true
        ) != nil)
        #expect(KeepAwakeCoordinator.decide(
            reasons: [], mode: .always, powerSource: .battery, allowsBattery: false
        ) == nil)
    }

    /// The network type is what Apple documents for a host serving remote
    /// clients, and it only applies on AC.
    @Test func remoteControlPicksTheNetworkAssertionOnlyOnAC() {
        let remote = [KeepAwakeReason(taskID: UUID(), tabID: UUID(), kind: .remoteControl)]
        #expect(KeepAwakeCoordinator.decide(
            reasons: remote, mode: .auto, powerSource: .ac, allowsBattery: true
        )?.type == .networkClientActive)
        #expect(KeepAwakeCoordinator.decide(
            reasons: remote, mode: .auto, powerSource: .battery, allowsBattery: true
        )?.type == .preventIdleSystemSleep)

        let working = [KeepAwakeReason(taskID: UUID(), tabID: UUID(), kind: .working(.working))]
        #expect(KeepAwakeCoordinator.decide(
            reasons: working, mode: .auto, powerSource: .ac, allowsBattery: true
        )?.type == .preventIdleSystemSleep)
    }

    @Test func theReasonFitsWhatIOKitAccepts() {
        let many = (0..<50).map {
            KeepAwakeReason(taskID: UUID(), tabID: UUID(), kind: .working($0.isMultiple(of: 2) ? .working : .permissionNeeded))
        }
        let request = KeepAwakeCoordinator.decide(
            reasons: many, mode: .auto, powerSource: .ac, allowsBattery: false
        )
        #expect(request?.reason.count ?? 0 <= SleepAssertionRequest.reasonLimit)
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
