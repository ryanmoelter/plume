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

    /// Stands in for the daemon. `status` is settable so a test can play the
    /// approval flow, and every `apply` is recorded like the assertion's.
    private final class FakeLidSleepOverride: LidSleepOverride {
        var status: LidSleepOverrideStatus = .notRegistered
        private(set) var registerCalls = 0
        private(set) var applications: [Bool] = []
        private(set) var isEngaged = false

        func ensureRegistered() {
            registerCalls += 1
            if status == .notRegistered { status = .needsApproval }
        }

        /// Like the daemon, an unapproved helper cannot engage, so the ask is
        /// dropped and the next `apply` after approval is what takes.
        func apply(_ engaged: Bool) {
            let usable = status == .ready || status == .engaged
            let becomes = engaged && usable
            guard becomes != isEngaged else { return }
            applications.append(becomes)
            isEngaged = becomes
            if usable { status = becomes ? .engaged : .ready }
        }

        func refreshStatus() {}
    }

    private func makeSettings() -> AppSettings {
        AppSettings(defaults: UserDefaults(suiteName: "KeepAwakeTests-\(UUID().uuidString)")!)
    }

    private func makeCoordinator(
        engine: StatusEngine,
        sessions: HeadlessSessionManager? = nil,
        settings: AppSettings? = nil,
        assertion: FakeSleepAssertion? = nil,
        power: KeepAwakeCoordinator.PowerSnapshot = KeepAwakeCoordinator.PowerSnapshot(source: .ac, percent: nil, isCharging: false),
        lidOverride: FakeLidSleepOverride? = nil
    ) -> (KeepAwakeCoordinator, FakeSleepAssertion, AppSettings) {
        let settings = settings ?? makeSettings()
        let assertion = assertion ?? FakeSleepAssertion()
        let coordinator = KeepAwakeCoordinator(
            engine: engine,
            sessions: sessions ?? HeadlessSessionManager(),
            settings: settings,
            assertion: assertion,
            powerSnapshot: { power },
            lidOverride: lidOverride ?? FakeLidSleepOverride()
        )
        return (coordinator, assertion, settings)
    }

    private func battery(percent: Int? = nil, isCharging: Bool = false) -> KeepAwakeCoordinator.PowerSnapshot {
        KeepAwakeCoordinator.PowerSnapshot(source: .battery, percent: percent, isCharging: isCharging)
    }

    private let ac = KeepAwakeCoordinator.PowerSnapshot(source: .ac, percent: nil, isCharging: false)
    private let battery = KeepAwakeCoordinator.PowerSnapshot(source: .battery, percent: 80, isCharging: false)

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

    // MARK: - Background tasks

    /// A monitor or backgrounded command outlives the turn that started it,
    /// so the tab it belongs to reads `awaitingReply` while it runs.
    @Test func aBackgroundTaskAloneKeepsTheMacAwake() {
        let taskID = UUID()
        let tabID = UUID()
        let reasons = KeepAwakeCoordinator.deriveReasons(
            activeTabs: [],
            remoteControlledTabs: [],
            backgroundTaskTabs: [(taskID: taskID, tabID: tabID, kind: .monitor)]
        )

        #expect(reasons.map(\.kind) == [.backgroundTask(.monitor)])
        #expect(KeepAwakeCoordinator.decide(
            reasons: reasons, mode: .auto, power: ac, allowsBattery: false, batteryCutoffPercent: 20
        ) == .hold(SleepAssertionRequest(
            type: .preventIdleSystemSleep,
            reason: KeepAwakeCoordinator.summary(reasons: reasons, mode: .auto)
        )))
    }

    @Test func aWorkingTabWithABackgroundTaskIsTwoReasons() {
        let taskID = UUID()
        let tabID = UUID()
        let reasons = KeepAwakeCoordinator.deriveReasons(
            activeTabs: [(taskID: taskID, tabID: tabID, status: .working)],
            remoteControlledTabs: [],
            backgroundTaskTabs: [(taskID: taskID, tabID: tabID, kind: .backgroundCommand)]
        )

        #expect(reasons.count == 2)
        #expect(reasons.contains { $0.kind == .working(.working) })
        #expect(reasons.contains { $0.kind == .backgroundTask(.backgroundCommand) })
    }

    @Test func theTallyCountsBackgroundTasksSeparately() {
        let tracker = BackgroundTaskTracker()
        let engine = StatusEngine(backgroundTasks: tracker)
        let (coordinator, _, _) = makeCoordinator(engine: engine)
        let taskID = UUID()
        let working = UUID()
        let monitoring = UUID()

        engine.setStatus(.working, taskID: taskID, tabID: working)
        engine.setStatus(.awaitingReply, taskID: taskID, tabID: monitoring)
        tracker.replace(tabID: monitoring, entries: [BackgroundTaskTracker.Entry(
            id: "b1",
            kind: .monitor,
            startedAt: Date(),
            expiresAt: nil
        )])
        coordinator.refresh()

        #expect(coordinator.tally == (working: 1, backgroundTasks: 1, remotelyControlled: false))
    }

    /// `pmset -g assertions` mangles anything but ASCII, and the em dash in a
    /// monitor's own phrasing is exactly the kind of thing that could leak in.
    @Test func theSummaryNamesBackgroundTasksInASCII() {
        let taskID = UUID()
        let one = KeepAwakeCoordinator.summary(
            reasons: KeepAwakeCoordinator.deriveReasons(
                activeTabs: [],
                remoteControlledTabs: [],
                backgroundTaskTabs: [(taskID: taskID, tabID: UUID(), kind: .monitor)]
            ),
            mode: .auto
        )
        #expect(one == "Plume: 1 background task")
        #expect(one.allSatisfy { $0.isASCII })

        let several = KeepAwakeCoordinator.summary(
            reasons: KeepAwakeCoordinator.deriveReasons(
                activeTabs: [(taskID: taskID, tabID: UUID(), status: .working)],
                remoteControlledTabs: [],
                backgroundTaskTabs: [
                    (taskID: taskID, tabID: UUID(), kind: .monitor),
                    (taskID: taskID, tabID: UUID(), kind: .backgroundCommand),
                ]
            ),
            mode: .auto
        )
        #expect(several == "Plume: 1 tab working, 2 background tasks")
        #expect(several.allSatisfy { $0.isASCII })
    }

    // MARK: - Mode and power

    @Test func neverNeverHolds() {
        let reasons = KeepAwakeCoordinator.deriveReasons(
            activeTabs: [(taskID: UUID(), tabID: UUID(), status: .working)],
            remoteControlledTabs: []
        )
        #expect(KeepAwakeCoordinator.decide(
            reasons: reasons, mode: .never, power: ac, allowsBattery: true, batteryCutoffPercent: 20
        ) == .off(nil))
    }

    @Test func alwaysHoldsWithNoReasons() {
        let decision = KeepAwakeCoordinator.decide(
            reasons: [], mode: .always, power: ac, allowsBattery: false, batteryCutoffPercent: 20
        )
        guard case .hold(let request) = decision else {
            Issue.record("expected a hold, got \(decision)")
            return
        }
        #expect(request.reason.contains("Always"))
    }

    @Test func autoHoldsOnlyWithAReason() {
        #expect(KeepAwakeCoordinator.decide(
            reasons: [], mode: .auto, power: ac, allowsBattery: false, batteryCutoffPercent: 20
        ) == .off(nil))

        let working = [KeepAwakeReason(taskID: UUID(), tabID: UUID(), kind: .working(.working))]
        guard case .hold = KeepAwakeCoordinator.decide(
            reasons: working, mode: .auto, power: ac, allowsBattery: false, batteryCutoffPercent: 20
        ) else {
            Issue.record("expected a hold")
            return
        }
    }

    @Test func batteryHoldsOnlyWhenAllowed() {
        let working = [KeepAwakeReason(taskID: UUID(), tabID: UUID(), kind: .working(.working))]
        #expect(KeepAwakeCoordinator.decide(
            reasons: working, mode: .auto, power: battery(), allowsBattery: false, batteryCutoffPercent: 20
        ) == .off(.battery))
        guard case .hold = KeepAwakeCoordinator.decide(
            reasons: working, mode: .auto, power: battery(), allowsBattery: true, batteryCutoffPercent: 20
        ) else {
            Issue.record("expected a hold")
            return
        }
        #expect(KeepAwakeCoordinator.decide(
            reasons: [], mode: .always, power: battery(), allowsBattery: false, batteryCutoffPercent: 20
        ) == .off(.battery))
    }

    /// The network type is what Apple documents for a host serving remote
    /// clients, and it only applies on AC.
    @Test func remoteControlPicksTheNetworkAssertionOnlyOnAC() {
        let remote = [KeepAwakeReason(taskID: UUID(), tabID: UUID(), kind: .remoteControl)]
        #expect(type(for: remote, mode: .auto, power: ac, allowsBattery: true) == .networkClientActive)
        #expect(type(for: remote, mode: .auto, power: battery(), allowsBattery: true) == .preventIdleSystemSleep)

        let working = [KeepAwakeReason(taskID: UUID(), tabID: UUID(), kind: .working(.working))]
        #expect(type(for: working, mode: .auto, power: ac, allowsBattery: true) == .preventIdleSystemSleep)
    }

    private func type(
        for reasons: [KeepAwakeReason],
        mode: KeepAwakeMode,
        power: KeepAwakeCoordinator.PowerSnapshot,
        allowsBattery: Bool
    ) -> SleepAssertionType? {
        guard case .hold(let request) = KeepAwakeCoordinator.decide(
            reasons: reasons, mode: mode, power: power, allowsBattery: allowsBattery, batteryCutoffPercent: 20
        ) else { return nil }
        return request.type
    }

    @Test func theReasonFitsWhatIOKitAccepts() {
        let many = (0..<50).map {
            KeepAwakeReason(taskID: UUID(), tabID: UUID(), kind: .working($0.isMultiple(of: 2) ? .working : .permissionNeeded))
        }
        guard case .hold(let request) = KeepAwakeCoordinator.decide(
            reasons: many, mode: .auto, power: ac, allowsBattery: false, batteryCutoffPercent: 20
        ) else {
            Issue.record("expected a hold")
            return
        }
        #expect(request.reason.count <= SleepAssertionRequest.reasonLimit)
    }

    // MARK: - Battery cutoff

    @Test func cutoffOffsAtOrBelowTheThreshold() {
        let working = [KeepAwakeReason(taskID: UUID(), tabID: UUID(), kind: .working(.working))]

        #expect(KeepAwakeCoordinator.decide(
            reasons: working, mode: .auto, power: battery(percent: 20), allowsBattery: true, batteryCutoffPercent: 20
        ) == .off(.batteryLow(20)))

        guard case .hold = KeepAwakeCoordinator.decide(
            reasons: working, mode: .auto, power: battery(percent: 21), allowsBattery: true, batteryCutoffPercent: 20
        ) else {
            Issue.record("expected a hold at cutoff + 1")
            return
        }

        #expect(KeepAwakeCoordinator.decide(
            reasons: working, mode: .auto, power: battery(percent: 19), allowsBattery: true, batteryCutoffPercent: 20
        ) == .off(.batteryLow(19)))
    }

    @Test func chargingIgnoresTheCutoff() {
        let working = [KeepAwakeReason(taskID: UUID(), tabID: UUID(), kind: .working(.working))]
        guard case .hold = KeepAwakeCoordinator.decide(
            reasons: working,
            mode: .auto,
            power: battery(percent: 5, isCharging: true),
            allowsBattery: true,
            batteryCutoffPercent: 20
        ) else {
            Issue.record("expected a hold while charging, even below cutoff")
            return
        }
    }

    @Test func cutoffOfZeroNeverFires() {
        let working = [KeepAwakeReason(taskID: UUID(), tabID: UUID(), kind: .working(.working))]
        guard case .hold = KeepAwakeCoordinator.decide(
            reasons: working, mode: .auto, power: battery(percent: 1), allowsBattery: true, batteryCutoffPercent: 0
        ) else {
            Issue.record("expected a hold when the cutoff is off")
            return
        }
    }

    @Test func acIgnoresPercentEntirely() {
        let working = [KeepAwakeReason(taskID: UUID(), tabID: UUID(), kind: .working(.working))]
        guard case .hold = KeepAwakeCoordinator.decide(
            reasons: working, mode: .auto, power: ac, allowsBattery: true, batteryCutoffPercent: 100
        ) else {
            Issue.record("expected a hold on AC regardless of cutoff")
            return
        }
    }

    // MARK: - Off reason

    @Test func offReasonIsBatteryWhenBatteryBlocksAWantedHold() {
        let engine = StatusEngine()
        let (coordinator, _, settings) = makeCoordinator(engine: engine, power: battery())
        settings.keepsAwakeOnBattery = false

        engine.setStatus(.working, taskID: UUID(), tabID: UUID())
        coordinator.refresh()

        #expect(coordinator.isHolding == false)
        #expect(coordinator.offReason == .battery)
    }

    @Test func offReasonIsNilOnBatteryWhenAllowed() {
        let engine = StatusEngine()
        let (coordinator, _, settings) = makeCoordinator(engine: engine, power: battery(percent: 80))
        settings.keepsAwakeOnBattery = true

        engine.setStatus(.working, taskID: UUID(), tabID: UUID())
        coordinator.refresh()

        #expect(coordinator.isHolding)
        #expect(coordinator.offReason == nil)
    }

    @Test func offReasonIsBatteryLowWhenChargeDropsToTheCutoff() {
        let engine = StatusEngine()
        let (coordinator, _, settings) = makeCoordinator(engine: engine, power: battery(percent: 20))
        settings.keepsAwakeOnBattery = true
        settings.keepAwakeBatteryCutoffPercent = 20

        engine.setStatus(.working, taskID: UUID(), tabID: UUID())
        coordinator.refresh()

        #expect(coordinator.isHolding == false)
        #expect(coordinator.offReason == .batteryLow(20))
    }

    @Test func offReasonIsNilWithNothingWantingAHold() {
        let engine = StatusEngine()
        let (coordinator, _, _) = makeCoordinator(engine: engine, power: battery())
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
            powerSnapshot: { KeepAwakeCoordinator.PowerSnapshot(source: .ac, percent: nil, isCharging: false) },
            lidOverride: FakeLidSleepOverride()
        )

        engine.setStatus(.working, taskID: UUID(), tabID: UUID())
        coordinator.refresh()

        #expect(coordinator.isHolding == false)
        #expect(coordinator.offReason == .refused)
    }

    @Test func theSidebarTallyCountsWhatIsHolding() {
        let engine = StatusEngine()
        let (coordinator, _, _) = makeCoordinator(engine: engine)
        #expect(coordinator.tally == (working: 0, backgroundTasks: 0, remotelyControlled: false))

        let taskID = UUID()
        engine.setStatus(.working, taskID: taskID, tabID: UUID())
        coordinator.refresh()
        #expect(coordinator.tally == (working: 1, backgroundTasks: 0, remotelyControlled: false))

        engine.setStatus(.working, taskID: taskID, tabID: UUID())
        coordinator.refresh()
        #expect(coordinator.tally == (working: 2, backgroundTasks: 0, remotelyControlled: false))
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

    // MARK: - The lid-closed override

    private func hold() -> KeepAwakeCoordinator.Decision {
        .hold(SleepAssertionRequest(type: .preventIdleSystemSleep, reason: "test"))
    }

    /// The override follows the hold and nothing else, so the coworker on
    /// battery with both toggles on gets it, and the same person with
    /// battery disallowed does not.
    @Test func theLidOverrideFollowsTheHold() {
        #expect(KeepAwakeCoordinator.decideLidOverride(decision: hold(), wantsLidClosed: true))
        #expect(KeepAwakeCoordinator.decideLidOverride(decision: hold(), wantsLidClosed: false) == false)
        #expect(KeepAwakeCoordinator.decideLidOverride(decision: .off(nil), wantsLidClosed: true) == false)
        #expect(KeepAwakeCoordinator.decideLidOverride(decision: .off(.battery), wantsLidClosed: true) == false)
        #expect(KeepAwakeCoordinator.decideLidOverride(decision: .off(.refused), wantsLidClosed: true) == false)

        let working = [KeepAwakeReason(taskID: UUID(), tabID: UUID(), kind: .working(.working))]
        let allowed = KeepAwakeCoordinator.decide(
            reasons: working, mode: .auto, power: battery, allowsBattery: true, batteryCutoffPercent: 0
        )
        #expect(KeepAwakeCoordinator.decideLidOverride(decision: allowed, wantsLidClosed: true))
        let blocked = KeepAwakeCoordinator.decide(
            reasons: working, mode: .auto, power: battery, allowsBattery: false, batteryCutoffPercent: 0
        )
        #expect(KeepAwakeCoordinator.decideLidOverride(decision: blocked, wantsLidClosed: true) == false)
    }

    @Test func theSettingOffNeverTouchesTheHelper() {
        let engine = StatusEngine()
        let lid = FakeLidSleepOverride()
        lid.status = .ready
        let (coordinator, _, _) = makeCoordinator(engine: engine, lidOverride: lid)

        engine.setStatus(.working, taskID: UUID(), tabID: UUID())
        coordinator.refresh()

        #expect(lid.registerCalls == 0)
        #expect(lid.applications.isEmpty)
        #expect(coordinator.lidOverrideStatus == .ready)
    }

    @Test func turningTheSettingOnRegistersAndEngagesWithTheHold() {
        let engine = StatusEngine()
        let lid = FakeLidSleepOverride()
        lid.status = .ready
        let (coordinator, assertion, settings) = makeCoordinator(engine: engine, lidOverride: lid)
        settings.keepsAwakeWithLidClosed = true

        coordinator.refresh()
        #expect(lid.registerCalls == 1)
        #expect(lid.applications.isEmpty, "nothing is working yet")

        engine.setStatus(.working, taskID: UUID(), tabID: UUID())
        coordinator.refresh()
        #expect(assertion.held != nil)
        #expect(lid.applications == [true])
        #expect(coordinator.lidOverrideStatus == .engaged)
    }

    @Test func statusEventsDoNotChurnTheLidOverride() {
        let engine = StatusEngine()
        let lid = FakeLidSleepOverride()
        lid.status = .ready
        let (coordinator, _, settings) = makeCoordinator(engine: engine, lidOverride: lid)
        settings.keepsAwakeWithLidClosed = true
        let taskID = UUID()
        let tabID = UUID()

        for _ in 0..<10 {
            engine.setStatus(.working, taskID: taskID, tabID: tabID)
            coordinator.refresh()
        }
        #expect(lid.applications == [true])
    }

    @Test func theLidOverrideReleasesWhenWorkStops() {
        let engine = StatusEngine()
        let lid = FakeLidSleepOverride()
        lid.status = .ready
        let (coordinator, _, settings) = makeCoordinator(engine: engine, lidOverride: lid)
        settings.keepsAwakeWithLidClosed = true
        let taskID = UUID()
        let tabID = UUID()

        engine.setStatus(.working, taskID: taskID, tabID: tabID)
        coordinator.refresh()
        engine.setStatus(.awaitingReply, taskID: taskID, tabID: tabID)
        coordinator.refresh()

        #expect(lid.applications == [true, false])
        #expect(coordinator.lidOverrideStatus == .ready)
    }

    /// Turning the setting off releases the override but leaves the plain
    /// assertion, which the user still wants.
    @Test func turningTheSettingOffReleasesOnlyTheLidOverride() {
        let engine = StatusEngine()
        let lid = FakeLidSleepOverride()
        lid.status = .ready
        let (coordinator, assertion, settings) = makeCoordinator(engine: engine, lidOverride: lid)
        settings.keepsAwakeWithLidClosed = true
        engine.setStatus(.working, taskID: UUID(), tabID: UUID())
        coordinator.refresh()
        #expect(lid.isEngaged)

        settings.keepsAwakeWithLidClosed = false
        coordinator.refresh()
        #expect(lid.isEngaged == false)
        #expect(assertion.held != nil)
        #expect(assertion.applications.count == 1)
    }

    @Test func terminationReleasesTheLidOverride() {
        let engine = StatusEngine()
        let lid = FakeLidSleepOverride()
        lid.status = .ready
        let (coordinator, _, settings) = makeCoordinator(engine: engine, lidOverride: lid)
        settings.keepsAwakeWithLidClosed = true
        engine.setStatus(.working, taskID: UUID(), tabID: UUID())
        coordinator.refresh()
        #expect(lid.isEngaged)

        coordinator.releaseForTermination()
        #expect(lid.isEngaged == false)
    }

    /// A helper still waiting on Login Items gets asked and stays unengaged,
    /// and the panel sees that state through the coordinator.
    @Test func anUnapprovedHelperIsReportedNotEngaged() {
        let engine = StatusEngine()
        let lid = FakeLidSleepOverride()
        let (coordinator, assertion, settings) = makeCoordinator(engine: engine, lidOverride: lid)
        settings.keepsAwakeWithLidClosed = true
        engine.setStatus(.working, taskID: UUID(), tabID: UUID())
        coordinator.refresh()

        #expect(assertion.held != nil)
        #expect(coordinator.lidOverrideStatus == .needsApproval)

        lid.status = .ready
        coordinator.refreshLidOverride()
        #expect(coordinator.lidOverrideStatus == .ready)
        coordinator.refresh()
        #expect(coordinator.lidOverrideStatus == .engaged)
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
        #expect(settings.keepsAwakeWithLidClosed == false)

        settings.keepAwakeMode = .always
        settings.keepsAwakeOnBattery = true
        settings.keepsAwakeWithLidClosed = true

        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.keepAwakeMode == .always)
        #expect(reloaded.keepsAwakeOnBattery)
        #expect(reloaded.keepsAwakeWithLidClosed)
    }

    @Test func anUnrecognizedModeFallsBackToAuto() {
        let defaults = UserDefaults(suiteName: "KeepAwakeTests-\(UUID().uuidString)")!
        defaults.set("sometimes", forKey: "keepAwakeModeRaw")
        #expect(AppSettings(defaults: defaults).keepAwakeMode == .auto)
    }

    @Test func batteryCutoffDefaultsTo20AndPersists() {
        let defaults = UserDefaults(suiteName: "KeepAwakeTests-\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        #expect(settings.keepAwakeBatteryCutoffPercent == 20)

        settings.keepAwakeBatteryCutoffPercent = 35
        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.keepAwakeBatteryCutoffPercent == 35)
    }

    @Test func batteryCutoffClampsTo0And100() {
        let settings = makeSettings()
        settings.keepAwakeBatteryCutoffPercent = -10
        #expect(settings.keepAwakeBatteryCutoffPercent == 0)

        settings.keepAwakeBatteryCutoffPercent = 150
        #expect(settings.keepAwakeBatteryCutoffPercent == 100)
    }

    // MARK: - Battery glyph

    @Test func batteryGlyphBucketsThePercentage() {
        let cases: [(Int?, String)] = [
            (nil, "battery.25percent"),
            (0, "battery.0percent"),
            (12, "battery.0percent"),
            (13, "battery.25percent"),
            (37, "battery.25percent"),
            (38, "battery.50percent"),
            (62, "battery.50percent"),
            (63, "battery.75percent"),
            (87, "battery.75percent"),
            (88, "battery.100percent"),
            (100, "battery.100percent"),
        ]
        for (percent, expected) in cases {
            #expect(SidebarFooter.batteryGlyph(percent: percent) == expected, "\(String(describing: percent))")
        }
    }
}

/// Covers what the keep-awake UI tells the user about closing the lid.
///
/// No assertion type survives a lid close; only the helper's override does.
/// So the guidance warns until the override is actually usable, and only then
/// says the lid can close.
@MainActor
struct LidCloseGuidanceTests {
    @Test func aLidThatSleepsWarnsAndOffersSettings() {
        let guidance = LidCloseGuidance.resolve(mode: .auto, wantsLidClosed: false, override: .notRegistered)
        #expect(guidance == .sleepsOnLidClose)
        #expect(guidance.summary != nil)
        #expect(guidance.explanation != nil)
        #expect(guidance.offersSystemSettings)
        #expect(guidance.offersLoginItems == false)
    }

    /// An approved helper that is not engaged still sleeps the Mac on lid
    /// close right now, so with the setting off it warns like any other.
    @Test func aReadyHelperWithTheSettingOffStillWarns() {
        #expect(LidCloseGuidance.resolve(mode: .auto, wantsLidClosed: false, override: .ready) == .sleepsOnLidClose)
    }

    @Test func aReadyHelperWithTheSettingOnPromisesOnlyWhileHolding() {
        let guidance = LidCloseGuidance.resolve(mode: .auto, wantsLidClosed: true, override: .ready)
        #expect(guidance == .staysAwakeWhileHolding)
        #expect(guidance.summary?.lowercased().contains("holding") == true)
        #expect(guidance.offersSystemSettings == false)
    }

    @Test func anEngagedHelperSaysTheLidCanClose() {
        let guidance = LidCloseGuidance.resolve(mode: .auto, wantsLidClosed: true, override: .engaged)
        #expect(guidance == .staysAwakeViaHelper)
        #expect(guidance.summary != nil)
        #expect(guidance.explanation == nil)
        #expect(guidance.offersSystemSettings == false)
    }

    @Test func anUnapprovedHelperPointsAtLoginItems() {
        let guidance = LidCloseGuidance.resolve(mode: .auto, wantsLidClosed: true, override: .needsApproval)
        #expect(guidance == .helperNeedsApproval)
        #expect(guidance.offersLoginItems)
        #expect(guidance.offersSystemSettings == false)
    }

    @Test func aFailedHelperShowsItsReason() {
        let guidance = LidCloseGuidance.resolve(mode: .auto, wantsLidClosed: true, override: .unavailable("nope"))
        #expect(guidance == .helperUnavailable("nope"))
        #expect(guidance.summary == "nope")
    }

    /// Never mode means the user declined Plume's say over sleep, so lid
    /// advice would be noise whatever the helper reports.
    @Test func neverModeSuppressesLidAdvice() {
        for override in [LidSleepOverrideStatus.notRegistered, .needsApproval, .ready, .engaged, .unavailable("x")] {
            let guidance = LidCloseGuidance.resolve(mode: .never, wantsLidClosed: true, override: override)
            #expect(guidance == .notApplicable, "\(override)")
            #expect(guidance.summary == nil, "\(override)")
        }
    }

    @Test func alwaysModeStillWarnsAboutTheLid() {
        #expect(LidCloseGuidance.resolve(mode: .always, wantsLidClosed: false, override: .notRegistered) == .sleepsOnLidClose)
    }

    /// Until the override is in effect the text must not read as a promise
    /// Plume cannot keep.
    @Test func theWarningNeverPromisesTheMacStaysAwake() {
        for override in [LidSleepOverrideStatus.notRegistered, .needsApproval] {
            let guidance = LidCloseGuidance.resolve(mode: .auto, wantsLidClosed: true, override: override)
            let text = ((guidance.summary ?? "") + " " + (guidance.explanation ?? "")).lowercased()
            #expect(!text.contains("can stay closed"), "\(override)")
        }
        let sleeps = LidCloseGuidance.resolve(mode: .auto, wantsLidClosed: false, override: .notRegistered)
        #expect(sleeps.summary?.lowercased().contains("sleeps") == true)
    }

    /// And once it is in effect the text says so, in plain terms.
    @Test func theHelperStateDoesPromiseTheLidCanClose() {
        let guidance = LidCloseGuidance.resolve(mode: .auto, wantsLidClosed: true, override: .engaged)
        #expect(guidance.summary?.lowercased().contains("can stay closed") == true)
    }
}
