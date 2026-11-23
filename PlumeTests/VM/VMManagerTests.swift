import Foundation
import Testing
import Virtualization
@testable import Plume

/// Each step completes at once unless held, so a test can catch a boot between steps.
@MainActor
final class FakeVMBackend: VMBackend {
    var hostOSMajor = 27
    var guestDidStop: ((_ slot: Int, _ generation: UInt64, _ reason: String?) -> Void)?

    var baseExists = true
    var heldElsewhere: Set<Int> = []
    var startError: [Int: any Error] = [:]
    var holdStart = false
    var holdPrepare = false
    var holdReady = false
    var holdStop = false
    var holdDelete = false
    /// A held prepare ends with `CancellationError` when its boot is cancelled, as a killed `tart clone` does.
    var prepareHonorsCancellation = false
    var stopFails: Set<Int> = []
    private(set) var terminationGracePeriod: TimeInterval?
    private(set) var startGenerations: [Int: UInt64] = [:]
    private(set) var calls: [String] = []
    private(set) var stopped: [Int] = []
    private(set) var stopIPs: [String?] = []
    private(set) var deleted: [Int] = []
    private(set) var cancelledPrepares: [Int] = []
    private var heldStarts: [Int: CheckedContinuation<VMDisplay?, any Error>] = [:]
    private var heldPrepares: [Int: CheckedContinuation<Void, any Error>] = [:]
    private var heldReadies: [Int: CheckedContinuation<Void, Never>] = [:]
    private var heldStops: [Int: CheckedContinuation<Void, Never>] = [:]
    private var heldDeletes: [Int: CheckedContinuation<Void, Never>] = [:]

    func baseImageExists() async -> Bool { baseExists }
    func clonesHeldElsewhere() async -> Set<Int> { heldElsewhere }

    func prepareClone(slot: Int) async throws {
        if holdPrepare, prepareHonorsCancellation {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { heldPrepares[slot] = $0 }
            } onCancel: {
                Task { @MainActor in self.cancelPrepare(slot) }
            }
        } else if holdPrepare {
            try await withCheckedThrowingContinuation { heldPrepares[slot] = $0 }
        }
        calls.append("prepare \(slot)")
    }

    private func cancelPrepare(_ slot: Int) {
        guard let prepare = heldPrepares.removeValue(forKey: slot) else { return }
        cancelledPrepares.append(slot)
        prepare.resume(throwing: CancellationError())
    }

    func isPrepareHeld(_ slot: Int) -> Bool { heldPrepares[slot] != nil }
    func finishPrepare(_ slot: Int) { heldPrepares.removeValue(forKey: slot)?.resume() }

    /// Ends a held prepare the way a killed `tart clone` does.
    func beginTermination(gracePeriod: TimeInterval) {
        terminationGracePeriod = gracePeriod
        for (_, prepare) in heldPrepares { prepare.resume(throwing: CancellationError()) }
        heldPrepares = [:]
    }

    func start(slot: Int, generation: UInt64, worktree: String?) async throws -> VMDisplay? {
        calls.append("start \(slot) \(worktree ?? "-")")
        startGenerations[slot] = generation
        if let error = startError[slot] { throw error }
        guard holdStart else { return nil }
        return try await withCheckedThrowingContinuation { heldStarts[slot] = $0 }
    }

    func isStartHeld(_ slot: Int) -> Bool { heldStarts[slot] != nil }

    func finishStart(_ slot: Int) {
        heldStarts.removeValue(forKey: slot)?.resume(returning: nil)
    }

    func waitUntilReady(slot: Int, onAddress: (String) -> Void) async throws -> String {
        let ip = "192.168.64.\(slot + 1)"
        onAddress(ip)
        if holdReady { await withCheckedContinuation { heldReadies[slot] = $0 } }
        calls.append("ready \(slot)")
        return ip
    }

    func isReadyHeld(_ slot: Int) -> Bool { heldReadies[slot] != nil }
    func finishReady(_ slot: Int) { heldReadies.removeValue(forKey: slot)?.resume() }

    func stop(slot: Int, ip: String?) async -> Bool {
        calls.append("stop \(slot)")
        if holdStop { await withCheckedContinuation { heldStops[slot] = $0 } }
        guard !stopFails.contains(slot) else { return false }
        stopped.append(slot)
        stopIPs.append(ip)
        return true
    }

    func isStopHeld(_ slot: Int) -> Bool { heldStops[slot] != nil }
    func finishStop(_ slot: Int) { heldStops.removeValue(forKey: slot)?.resume() }

    func deleteClone(slot: Int) async throws {
        calls.append("delete \(slot)")
        if holdDelete { await withCheckedContinuation { heldDeletes[slot] = $0 } }
        deleted.append(slot)
    }

    func isDeleteHeld(_ slot: Int) -> Bool { heldDeletes[slot] != nil }
    func finishDelete(_ slot: Int) { heldDeletes.removeValue(forKey: slot)?.resume() }
}

@MainActor
final class VMTestClock {
    var date = Date(timeIntervalSince1970: 2_000_000)
}

/// The lease and boot state machine behind `plume devices claim --kind=vm`, against a fake host.
@MainActor
struct VMManagerTests {
    let backend = FakeVMBackend()
    let clock = VMTestClock()
    let manager: VMManager

    init() {
        manager = VMManager(backend: backend)
        let clock = clock
        manager.now = { clock.date }
    }

    func settle(until condition: () -> Bool = { false }) async {
        for _ in 0..<500 {
            if condition() { return }
            await Task.yield()
        }
    }

    func state(_ slot: Int) -> VMSlotState? { manager.slot(slot)?.state }

    @Test func claimsSlotsInOrderAndTheThirdFindsThePoolFull() async throws {
        #expect(try await manager.claim(owner: .label("a"), worktree: "/wt/a", branch: "a").slot == 1)
        #expect(try await manager.claim(owner: .label("b"), worktree: "/wt/b", branch: "b").slot == 2)
        await settle { state(1) == .ready && state(2) == .ready }
        #expect(state(1) == .ready)
        #expect(state(2) == .ready)
        #expect(manager.slot(1)?.ip == "192.168.64.2")
        #expect(backend.calls.contains("start 1 /wt/a"))
        await #expect(throws: VMManager.Failure.poolFull) { try await manager.claim(owner: .label("c"), worktree: nil, branch: nil) }
    }

    @Test func aSlotAnotherPlumeHoldsIsSkipped() async throws {
        backend.heldElsewhere = [1]
        #expect(try await manager.claim(owner: .label("a"), worktree: nil, branch: nil).slot == 2)
        await #expect(throws: VMManager.Failure.poolFull) { try await manager.claim(owner: .label("b"), worktree: nil, branch: nil) }
        #expect(manager.info(1).heldElsewhere == true)
    }

    @Test func aMissingBaseNamesTheScript() async {
        backend.baseExists = false
        await #expect(throws: VMManager.Failure.missingBase("plume-base-27")) {
            try await manager.claim(owner: .label("a"), worktree: nil, branch: nil)
        }
        #expect(VMManager.Failure.missingBase("plume-base-27").localizedDescription.contains("scripts/vm/make-base-image.sh"))
    }

    @Test func claimingAgainRenews() async throws {
        _ = try await manager.claim(owner: .label("a"), worktree: "/wt", branch: nil, ttl: 60)
        await settle { state(1) == .ready }
        clock.date += 30
        let again = try await manager.claim(owner: .label("a"), worktree: "/wt", branch: nil, ttl: 600)
        #expect(again.slot == 1)
        #expect(again.reused)
        #expect(manager.slot(1)?.lease?.expiresAt == clock.date + 600)
        #expect(state(1) == .ready)
        #expect(backend.calls.filter { $0.hasPrefix("start") }.count == 1)
    }

    @Test func aDifferentWorktreeIsRefused() async throws {
        _ = try await manager.claim(owner: .label("a"), worktree: "/wt/one", branch: nil)
        await #expect(throws: VMManager.Failure.worktreeMismatch(key: "vm:1", held: "/wt/one", wanted: "/wt/two")) {
            try await manager.claim(owner: .label("a"), worktree: "/wt/two", branch: nil)
        }
    }

    @Test func theVirtualizationLimitReadsAsPoolFull() async throws {
        backend.startError[1] = NSError(domain: VZErrorDomain, code: 6)
        _ = try await manager.claim(owner: .label("a"), worktree: nil, branch: nil)
        await settle { state(1) == .failed }
        let info = manager.info(1)
        #expect(info.state == .failed)
        #expect(info.poolFull == true)
        #expect(info.error?.contains("VM pool full") == true)
        #expect(info.owner == .label("a"))
        await settle { backend.stopped == [1] }
        #expect(backend.stopped == [1])
    }

    @Test func expiryStopsTheVM() async throws {
        _ = try await manager.claim(owner: .label("a"), worktree: nil, branch: nil, ttl: 60)
        await settle { state(1) == .ready }
        clock.date += 59
        manager.reapExpired()
        #expect(state(1) == .ready)
        clock.date += 2
        manager.reapExpired()
        #expect(state(1) == .stopping)
        await settle { state(1) == .idle }
        #expect(state(1) == .idle)
        #expect(manager.slot(1)?.lease == nil)
        #expect(backend.stopped == [1])
    }

    @Test func releaseKeepsTheClone() async throws {
        _ = try await manager.claim(owner: .label("a"), worktree: nil, branch: nil)
        await settle { state(1) == .ready }
        try manager.release("vm:1", owner: .label("a"), force: false)
        await settle { state(1) == .idle }
        #expect(state(1) == .idle)
        #expect(backend.stopped == [1])
        #expect(backend.deleted.isEmpty)
    }

    @Test func releasingAnotherOwnersLeaseNeedsForce() async throws {
        _ = try await manager.claim(owner: .label("a"), worktree: nil, branch: nil)
        #expect(throws: VMManager.Failure.notOwner(key: "vm:1", holder: "a")) {
            try manager.release("vm:1", owner: .label("b"), force: false)
        }
        try manager.release("vm:1", owner: .label("b"), force: true)
        #expect(manager.slot(1)?.lease == nil)
        #expect(throws: VMManager.Failure.notLeased("vm:2")) { try manager.release("vm:2", owner: .label("a"), force: true) }
        #expect(throws: VMManager.Failure.unknownKey("vm:3")) { try manager.release("vm:3", owner: .label("a"), force: true) }
    }

    @Test func resetRefusesARunningSlot() async throws {
        _ = try await manager.claim(owner: .label("a"), worktree: nil, branch: nil)
        await settle { state(1) == .ready }
        await #expect(throws: VMManager.Failure.busy(key: "vm:1", state: .ready)) { try await manager.reset("vm:1") }
        try manager.release("vm:1", owner: .label("a"), force: false)
        await settle { state(1) == .idle }
        try await manager.reset("vm:1")
        #expect(backend.deleted == [1])
        #expect(state(1) == .idle)
    }

    @Test func resetRefusesAClonesAnotherPlumeHolds() async {
        backend.heldElsewhere = [2]
        await #expect(throws: VMManager.Failure.heldElsewhere("vm:2")) { try await manager.reset("vm:2") }
        #expect(backend.deleted.isEmpty)
    }

    @Test func forgettingTheOwnerTabReleasesItsVM() async throws {
        let tab = UUID()
        _ = try await manager.claim(owner: .tab(id: tab, app: "/app/cli.sock"), worktree: nil, branch: nil)
        _ = try await manager.claim(owner: .label("other"), worktree: nil, branch: nil)
        await settle { state(1) == .ready && state(2) == .ready }
        manager.tabForgotten(tab)
        await settle { state(1) == .idle }
        #expect(state(1) == .idle)
        #expect(state(2) == .ready)
        #expect(backend.stopped == [1])
    }

    @Test func aStaleBootCompletionIsIgnored() async throws {
        backend.holdStart = true
        _ = try await manager.claim(owner: .label("a"), worktree: nil, branch: nil)
        await settle { backend.isStartHeld(1) }
        #expect(state(1) == .starting)
        try manager.release("vm:1", owner: .label("a"), force: false)
        backend.finishStart(1)
        await settle { state(1) == .idle }
        #expect(state(1) == .idle)
        #expect(manager.displays[1] == nil)
        #expect(!backend.calls.contains("ready 1"))
    }

    @Test func releaseDuringAStartStopsTheVMOnceTheStartFinishes() async throws {
        backend.holdStart = true
        _ = try await manager.claim(owner: .label("a"), worktree: nil, branch: nil)
        await settle { backend.isStartHeld(1) }
        try manager.release("vm:1", owner: .label("a"), force: false)
        #expect(state(1) == .stopping)
        await settle()
        #expect(state(1) == .stopping)
        #expect(backend.stopped.isEmpty)
        backend.holdStart = false
        backend.finishStart(1)
        await settle { state(1) == .idle }
        #expect(backend.stopped == [1])
        #expect(try await manager.claim(owner: .label("b"), worktree: nil, branch: nil).slot == 1)
        await settle { state(1) == .ready }
        #expect(state(1) == .ready)
        #expect(manager.slot(1)?.lease?.owner == .label("b"))
    }

    @Test func aFailedBootBootsAgainOnTheNextClaim() async throws {
        backend.startError[1] = VMHost.Failure(message: "boom")
        _ = try await manager.claim(owner: .label("a"), worktree: nil, branch: nil)
        await settle { state(1) == .failed }
        #expect(manager.slot(1)?.error == "boom")
        backend.startError[1] = nil
        #expect(try await manager.claim(owner: .label("a"), worktree: nil, branch: nil).reused)
        await settle { state(1) == .ready }
        #expect(state(1) == .ready)
        #expect(manager.slot(1)?.error == nil)
    }

    @Test func installedIsRecordedOnTheLease() async throws {
        _ = try await manager.claim(owner: .label("a"), worktree: nil, branch: nil)
        try manager.noteInstalled("vm:1", branch: "feature", worktree: "/wt")
        #expect(manager.info(1).installed?.branch == "feature")
        #expect(throws: VMManager.Failure.notLeased("vm:2")) { try manager.noteInstalled("vm:2", branch: "x", worktree: nil) }
    }

    @Test func infoNamesThePathsAGuestUses() async throws {
        _ = try await manager.claim(owner: .label("a"), worktree: "/wt", branch: "main")
        let info = manager.info(1)
        #expect(info.key == "vm:1")
        #expect(info.clone == "plume-27-1")
        #expect(info.share.hasSuffix("/Plume/vms/vm1/share"))
        #expect(info.controlSocket.hasSuffix("/Plume/vms/vm1/control.sock"))
        #expect(info.guestShare == "/Volumes/My Shared Files/share")
        #expect(info.guestWorktree == "/Volumes/My Shared Files/worktree")
        #expect(info.user == "admin")
        #expect(info.sshKey.hasSuffix("/Plume/vms/id_ed25519"))
    }
    @Test func aReleaseWhileTheCloneIsPreparedStopsAfterIt() async throws {
        backend.holdPrepare = true
        _ = try await manager.claim(owner: .label("a"), worktree: nil, branch: nil)
        await settle { backend.isPrepareHeld(1) }
        try manager.release("vm:1", owner: .label("a"), force: false)
        await settle()
        #expect(backend.stopped.isEmpty)
        backend.finishPrepare(1)
        await settle { state(1) == .idle }
        #expect(backend.calls == ["prepare 1", "stop 1"])
    }

    @Test func aStopBeforeReadyShutsDownAtTheFoundAddress() async throws {
        backend.holdReady = true
        _ = try await manager.claim(owner: .label("a"), worktree: nil, branch: nil)
        await settle { backend.isReadyHeld(1) }
        #expect(state(1) == .starting)
        #expect(manager.slot(1)?.ip == "192.168.64.2")
        try manager.release("vm:1", owner: .label("a"), force: false)
        backend.finishReady(1)
        await settle { state(1) == .idle }
        #expect(backend.stopIPs == ["192.168.64.2"])
    }

    @Test func aFailedSlotStillStoppingCountsAsRunning() async throws {
        backend.holdStop = true
        backend.startError[1] = VMHost.Failure(message: "boom")
        _ = try await manager.claim(owner: .label("a"), worktree: nil, branch: nil)
        await settle { backend.isStopHeld(1) }
        #expect(state(1) == .failed)
        #expect(manager.runningCount == 1)
        backend.finishStop(1)
        await settle { manager.runningCount == 0 }
        #expect(manager.runningCount == 0)
    }

    @Test func aLiveVMTabsLeaseRenewsItselfAndClosingTheTabStopsIt() async throws {
        let vmTab = UUID()
        var live: Set<UUID> = [vmTab]
        manager.isLiveVMTab = { live.contains($0) }
        _ = try await manager.claim(owner: .tab(id: vmTab, app: "/app/cli.sock"), worktree: nil, branch: nil, ttl: 60)
        await settle { state(1) == .ready }
        clock.date += 120
        manager.reapExpired()
        #expect(state(1) == .ready)
        #expect(manager.slot(1)?.lease?.expiresAt == clock.date + VMManager.defaultTTL)
        live = []
        manager.tabForgotten(vmTab)
        await settle { state(1) == .idle }
        #expect(state(1) == .idle)
    }

    @Test func forgettingATabThatOnlyShowsAVMLeavesIt() async throws {
        _ = try await manager.claim(owner: .label("agent"), worktree: nil, branch: nil)
        await settle { state(1) == .ready }
        manager.tabForgotten(UUID())
        #expect(state(1) == .ready)
        #expect(backend.stopped.isEmpty)
    }

    @Test func quitAlertNamesAgentsAndVMsTogether() {
        #expect(AppDelegate.quitAlertText(agentsWorking: false, runningVMs: 0) == nil)
        let both = AppDelegate.quitAlertText(agentsWorking: true, runningVMs: 2)
        #expect(both?.title == "Quit While Agents Are Working and Stop 2 Running VMs?")
        #expect(both?.message.contains("agent") == true)
        #expect(both?.message.contains("VMs stop") == true)
        #expect(AppDelegate.quitAlertText(agentsWorking: false, runningVMs: 1)?.title == "Quit and Stop the Running VM?")
    }

    @Test func aGuestStopFromAnEarlierBootIsIgnored() async throws {
        _ = try await manager.claim(owner: .label("a"), worktree: nil, branch: nil)
        await settle { state(1) == .ready }
        let firstBoot = try #require(backend.startGenerations[1])
        try manager.release("vm:1", owner: .label("a"), force: false)
        await settle { state(1) == .idle }
        _ = try await manager.claim(owner: .label("b"), worktree: nil, branch: nil)
        await settle { state(1) == .ready }
        backend.guestDidStop?(1, firstBoot, "late")
        #expect(state(1) == .ready)
        backend.guestDidStop?(1, try #require(backend.startGenerations[1]), "crashed")
        #expect(state(1) == .failed)
        #expect(manager.slot(1)?.error == "vm:1 stopped: crashed")
    }

    @Test func aVMThatWontStopLeavesTheSlotFailed() async throws {
        backend.stopFails = [1]
        _ = try await manager.claim(owner: .label("a"), worktree: nil, branch: nil)
        await settle { state(1) == .ready }
        try manager.release("vm:1", owner: .label("a"), force: false)
        await settle { state(1) != .stopping }
        #expect(state(1) == .failed)
        #expect(manager.slot(1)?.error?.contains("didn't stop") == true)
    }

    @Test func quittingEndsACloneInFlightWithoutStartingTheVM() async throws {
        backend.holdPrepare = true
        _ = try await manager.claim(owner: .label("a"), worktree: nil, branch: nil)
        await settle { backend.isPrepareHeld(1) }
        await manager.stopAllForTermination()
        #expect(backend.terminationGracePeriod == VMManager.terminationGracePeriod)
        #expect(state(1) == .idle)
        #expect(backend.calls == ["stop 1"])
    }

    func stopFailsAfterRelease(_ slot: Int = 1) async throws {
        backend.stopFails = [slot]
        _ = try await manager.claim(owner: .label("a"), worktree: nil, branch: nil, preferred: slot)
        await settle { state(slot) == .ready }
        try manager.release(VMPaths.key(slot), owner: .label("a"), force: false)
        await settle { state(slot) == .failed }
    }

    @Test func aVMThatWontStopStillCountsAsRunning() async throws {
        try await stopFailsAfterRelease()
        #expect(manager.slot(1)?.stillRunning == true)
        #expect(manager.slot(1)?.lease == nil)
        #expect(manager.runningCount == 1)
    }

    @Test func aRetryStopsTheVMAgainBeforeBooting() async throws {
        try await stopFailsAfterRelease()
        _ = try await manager.claim(owner: .label("b"), worktree: nil, branch: nil, preferred: 1)
        await settle { state(1) == .failed && backend.calls.filter { $0 == "stop 1" }.count == 2 }
        #expect(state(1) == .failed)
        #expect(manager.slot(1)?.error?.contains("didn't stop") == true)
        #expect(backend.calls.filter { $0.hasPrefix("start") }.count == 1)

        backend.stopFails = []
        _ = try await manager.claim(owner: .label("b"), worktree: nil, branch: nil)
        await settle { state(1) == .ready }
        #expect(state(1) == .ready)
        #expect(manager.slot(1)?.stillRunning == false)
        #expect(Array(backend.calls.suffix(4)) == ["stop 1", "prepare 1", "start 1 -", "ready 1"])
    }

    @Test func releasingASlotWhoseVMWontStopStopsItAgain() async throws {
        try await stopFailsAfterRelease()
        backend.stopFails = []
        try manager.release("vm:1", owner: .label("anyone"), force: false)
        await settle { state(1) == .idle }
        #expect(state(1) == .idle)
        #expect(manager.slot(1)?.stillRunning == false)
        #expect(manager.runningCount == 0)
    }

    @Test func resetStopsAVMThatWontStopBeforeDeletingItsClone() async throws {
        try await stopFailsAfterRelease()
        await #expect(throws: VMManager.Failure.stillRunning("vm:1")) { try await manager.reset("vm:1") }
        #expect(backend.deleted.isEmpty)
        backend.stopFails = []
        try await manager.reset("vm:1")
        #expect(Array(backend.calls.suffix(2)) == ["stop 1", "delete 1"])
        #expect(state(1) == .idle)
    }

    @Test func aResetReadsResettingAndIsNotARunningVM() async throws {
        backend.holdDelete = true
        let reset = Task { try await manager.reset("vm:2") }
        await settle { backend.isDeleteHeld(2) }
        #expect(state(2) == .resetting)
        #expect(manager.runningCount == 0)
        await #expect(throws: VMManager.Failure.slotTaken("vm:2")) {
            try await manager.claim(owner: .label("a"), worktree: nil, branch: nil, preferred: 2)
        }
        backend.finishDelete(2)
        try await reset.value
        #expect(state(2) == .idle)
    }

    @Test func aReleaseCancelsACloneInFlight() async throws {
        backend.holdPrepare = true
        backend.prepareHonorsCancellation = true
        _ = try await manager.claim(owner: .label("a"), worktree: nil, branch: nil)
        await settle { backend.isPrepareHeld(1) }
        try manager.release("vm:1", owner: .label("a"), force: false)
        await settle { state(1) == .idle }
        #expect(state(1) == .idle)
        #expect(backend.cancelledPrepares == [1])
        #expect(backend.calls == ["stop 1"])
    }

    @Test func eachLeaseGetsItsOwnToken() async throws {
        _ = try await manager.claim(owner: .label("a"), worktree: nil, branch: nil)
        let first = try #require(manager.info(1).leaseToken)
        _ = try await manager.claim(owner: .label("a"), worktree: nil, branch: nil)
        #expect(manager.info(1).leaseToken == first)
        try manager.release("vm:1", owner: .label("a"), force: false)
        await settle { state(1) == .idle }
        _ = try await manager.claim(owner: .label("a"), worktree: nil, branch: nil)
        #expect(manager.info(1).leaseToken != first)
    }

    @Test func aWorktreeIsComparedWithSymlinksResolved() async throws {
        let real = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appending(path: "vm-wt-\(UUID().uuidString)")
        let link = FileManager.default.temporaryDirectory.appending(path: "vm-wt-link-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        defer {
            try? FileManager.default.removeItem(at: link)
            try? FileManager.default.removeItem(at: real)
        }
        _ = try await manager.claim(owner: .label("a"), worktree: real.path, branch: nil)
        #expect(try await manager.claim(owner: .label("a"), worktree: link.path, branch: nil).reused)
    }
}
