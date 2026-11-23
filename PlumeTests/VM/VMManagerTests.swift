import Foundation
import Testing
import Virtualization
@testable import Plume

/// Each step completes at once unless held, so a test can catch a boot between steps.
@MainActor
final class FakeVMBackend: VMBackend {
    var hostOSMajor = 27
    var guestDidStop: ((_ slot: Int, _ reason: String?) -> Void)?

    var baseExists = true
    var heldElsewhere: Set<Int> = []
    var startError: [Int: any Error] = [:]
    var holdStart = false
    private(set) var calls: [String] = []
    private(set) var stopped: [Int] = []
    private(set) var deleted: [Int] = []
    private var heldStarts: [Int: CheckedContinuation<VMDisplay?, any Error>] = [:]

    func baseImageExists() -> Bool { baseExists }
    func isCloneFree(slot: Int) -> Bool { !heldElsewhere.contains(slot) }

    func prepareClone(slot: Int) async throws { calls.append("prepare \(slot)") }

    func start(slot: Int, worktree: String?) async throws -> VMDisplay? {
        calls.append("start \(slot) \(worktree ?? "-")")
        if let error = startError[slot] { throw error }
        guard holdStart else { return nil }
        return try await withCheckedThrowingContinuation { heldStarts[slot] = $0 }
    }

    func isStartHeld(_ slot: Int) -> Bool { heldStarts[slot] != nil }

    func finishStart(_ slot: Int) {
        heldStarts.removeValue(forKey: slot)?.resume(returning: nil)
    }

    func waitUntilReady(slot: Int) async throws -> String {
        calls.append("ready \(slot)")
        return "192.168.64.\(slot + 1)"
    }

    func stop(slot: Int, ip: String?) async { stopped.append(slot) }

    func deleteClone(slot: Int) async throws { deleted.append(slot) }
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
        #expect(try manager.claim(owner: .label("a"), worktree: "/wt/a", branch: "a").slot == 1)
        #expect(try manager.claim(owner: .label("b"), worktree: "/wt/b", branch: "b").slot == 2)
        await settle { state(1) == .ready && state(2) == .ready }
        #expect(state(1) == .ready)
        #expect(state(2) == .ready)
        #expect(manager.slot(1)?.ip == "192.168.64.2")
        #expect(backend.calls.contains("start 1 /wt/a"))
        #expect(throws: VMManager.Failure.poolFull) { try manager.claim(owner: .label("c"), worktree: nil, branch: nil) }
    }

    @Test func aSlotAnotherPlumeHoldsIsSkipped() throws {
        backend.heldElsewhere = [1]
        #expect(try manager.claim(owner: .label("a"), worktree: nil, branch: nil).slot == 2)
        #expect(throws: VMManager.Failure.poolFull) { try manager.claim(owner: .label("b"), worktree: nil, branch: nil) }
        #expect(manager.info(1).heldElsewhere == true)
    }

    @Test func aMissingBaseNamesTheScript() {
        backend.baseExists = false
        #expect(throws: VMManager.Failure.missingBase("plume-base-27")) {
            try manager.claim(owner: .label("a"), worktree: nil, branch: nil)
        }
        #expect(VMManager.Failure.missingBase("plume-base-27").localizedDescription.contains("scripts/vm/make-base-image.sh"))
    }

    @Test func claimingAgainRenews() async throws {
        _ = try manager.claim(owner: .label("a"), worktree: "/wt", branch: nil, ttl: 60)
        await settle { state(1) == .ready }
        clock.date += 30
        let again = try manager.claim(owner: .label("a"), worktree: "/wt", branch: nil, ttl: 600)
        #expect(again.slot == 1)
        #expect(again.reused)
        #expect(manager.slot(1)?.lease?.expiresAt == clock.date + 600)
        #expect(state(1) == .ready)
        #expect(backend.calls.filter { $0.hasPrefix("start") }.count == 1)
    }

    @Test func aDifferentWorktreeIsRefused() throws {
        _ = try manager.claim(owner: .label("a"), worktree: "/wt/one", branch: nil)
        #expect(throws: VMManager.Failure.worktreeMismatch(key: "vm:1", held: "/wt/one", wanted: "/wt/two")) {
            try manager.claim(owner: .label("a"), worktree: "/wt/two", branch: nil)
        }
    }

    @Test func theVirtualizationLimitReadsAsPoolFull() async throws {
        backend.startError[1] = NSError(domain: VZErrorDomain, code: 6)
        _ = try manager.claim(owner: .label("a"), worktree: nil, branch: nil)
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
        _ = try manager.claim(owner: .label("a"), worktree: nil, branch: nil, ttl: 60)
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
        _ = try manager.claim(owner: .label("a"), worktree: nil, branch: nil)
        await settle { state(1) == .ready }
        try manager.release("vm:1", owner: .label("a"), force: false)
        await settle { state(1) == .idle }
        #expect(state(1) == .idle)
        #expect(backend.stopped == [1])
        #expect(backend.deleted.isEmpty)
    }

    @Test func releasingAnotherOwnersLeaseNeedsForce() async throws {
        _ = try manager.claim(owner: .label("a"), worktree: nil, branch: nil)
        #expect(throws: VMManager.Failure.notOwner(key: "vm:1", holder: "a")) {
            try manager.release("vm:1", owner: .label("b"), force: false)
        }
        try manager.release("vm:1", owner: .label("b"), force: true)
        #expect(manager.slot(1)?.lease == nil)
        #expect(throws: VMManager.Failure.notLeased("vm:2")) { try manager.release("vm:2", owner: .label("a"), force: true) }
        #expect(throws: VMManager.Failure.unknownKey("vm:3")) { try manager.release("vm:3", owner: .label("a"), force: true) }
    }

    @Test func resetRefusesARunningSlot() async throws {
        _ = try manager.claim(owner: .label("a"), worktree: nil, branch: nil)
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
        _ = try manager.claim(owner: .tab(id: tab, app: "/app/cli.sock"), worktree: nil, branch: nil)
        _ = try manager.claim(owner: .label("other"), worktree: nil, branch: nil)
        await settle { state(1) == .ready && state(2) == .ready }
        manager.tabForgotten(tab)
        await settle { state(1) == .idle }
        #expect(state(1) == .idle)
        #expect(state(2) == .ready)
        #expect(backend.stopped == [1])
    }

    @Test func aStaleBootCompletionIsIgnored() async throws {
        backend.holdStart = true
        _ = try manager.claim(owner: .label("a"), worktree: nil, branch: nil)
        await settle { backend.isStartHeld(1) }
        #expect(state(1) == .starting)
        try manager.release("vm:1", owner: .label("a"), force: false)
        await settle { state(1) == .idle }
        backend.finishStart(1)
        await settle()
        #expect(state(1) == .idle)
        #expect(manager.displays[1] == nil)
        #expect(!backend.calls.contains("ready 1"))
    }

    @Test func releaseDuringBootStopsTheSlotAndFreesIt() async throws {
        backend.holdStart = true
        _ = try manager.claim(owner: .label("a"), worktree: nil, branch: nil)
        await settle { backend.isStartHeld(1) }
        try manager.release("vm:1", owner: .label("a"), force: false)
        #expect(state(1) == .stopping)
        await settle { state(1) == .idle }
        #expect(backend.stopped == [1])
        backend.holdStart = false
        backend.finishStart(1)
        #expect(try manager.claim(owner: .label("b"), worktree: nil, branch: nil).slot == 1)
        await settle { state(1) == .ready }
        #expect(state(1) == .ready)
        #expect(manager.slot(1)?.lease?.owner == .label("b"))
    }

    @Test func aFailedBootBootsAgainOnTheNextClaim() async throws {
        backend.startError[1] = VMHost.Failure(message: "boom")
        _ = try manager.claim(owner: .label("a"), worktree: nil, branch: nil)
        await settle { state(1) == .failed }
        #expect(manager.slot(1)?.error == "boom")
        backend.startError[1] = nil
        #expect(try manager.claim(owner: .label("a"), worktree: nil, branch: nil).reused)
        await settle { state(1) == .ready }
        #expect(state(1) == .ready)
        #expect(manager.slot(1)?.error == nil)
    }

    @Test func installedIsRecordedOnTheLease() throws {
        _ = try manager.claim(owner: .label("a"), worktree: nil, branch: nil)
        try manager.noteInstalled("vm:1", branch: "feature", worktree: "/wt")
        #expect(manager.info(1).installed?.branch == "feature")
        #expect(throws: VMManager.Failure.notLeased("vm:2")) { try manager.noteInstalled("vm:2", branch: "x", worktree: nil) }
    }

    @Test func infoNamesThePathsAGuestUses() throws {
        _ = try manager.claim(owner: .label("a"), worktree: "/wt", branch: "main")
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
}
