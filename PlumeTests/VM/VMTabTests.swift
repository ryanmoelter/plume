import Foundation
import SwiftData
import Testing
@testable import Plume

/// What a VM tab shows for its slot, which tab a claim from another tab lands in, the device
/// picker's VM rows and claim of one particular slot, and a device tab turning into a VM tab and back
/// in place.
@MainActor
struct VMTabTests {
    private func slot(_ state: VMSlotState, leased: Bool = false, error: String? = nil) -> VMManager.Slot {
        var slot = VMManager.Slot(number: 1)
        slot.state = state
        slot.error = error
        if leased {
            let now = Date(timeIntervalSince1970: 0)
            slot.lease = VMManager.Lease(owner: .label("a"), claimedAt: now, expiresAt: now + 60)
        }
        return slot
    }

    @Test func noSlotChosenLeavesTheVMTab() {
        #expect(VMTabPhase.of(vmSlot: 0, slot: slot(.ready, leased: true), hasDisplay: true) == .picker)
        #expect(VMTabPhase.of(vmSlot: 3, slot: nil, hasDisplay: false) == .picker)
    }

    @Test func aReleasedSlotReadsIdle() {
        #expect(VMTabPhase.of(vmSlot: 1, slot: slot(.idle), hasDisplay: false) == .idle(slot: 1))
    }

    @Test func aJustClaimedSlotReadsBooting() {
        #expect(VMTabPhase.of(vmSlot: 1, slot: slot(.idle, leased: true), hasDisplay: false) == .booting(slot: 1, state: .reserved))
        #expect(VMTabPhase.of(vmSlot: 1, slot: slot(.cloning, leased: true), hasDisplay: false) == .booting(slot: 1, state: .cloning))
        #expect(VMTabPhase.of(vmSlot: 1, slot: slot(.starting, leased: true), hasDisplay: true) == .booting(slot: 1, state: .starting))
    }

    @Test func readyFollowsTheDisplay() {
        #expect(VMTabPhase.of(vmSlot: 1, slot: slot(.ready, leased: true), hasDisplay: true) == .running(slot: 1, hasDisplay: true))
        #expect(VMTabPhase.of(vmSlot: 1, slot: slot(.ready, leased: true), hasDisplay: false).label == "running, no display")
    }

    @Test func failedCarriesTheErrorAndWhetherTheLeaseSurvived() {
        #expect(
            VMTabPhase.of(vmSlot: 1, slot: slot(.failed, leased: true, error: "boom"), hasDisplay: false)
                == .failed(slot: 1, message: "boom", leased: true)
        )
        #expect(
            VMTabPhase.of(vmSlot: 1, slot: slot(.failed), hasDisplay: false)
                == .failed(slot: 1, message: "vm:1 failed", leased: false)
        )
    }

    @Test func stoppingReadsStopping() {
        #expect(VMTabPhase.of(vmSlot: 1, slot: slot(.stopping), hasDisplay: false) == .stopping(slot: 1))
    }

    @Test func resettingReadsResetting() {
        #expect(VMTabPhase.of(vmSlot: 1, slot: slot(.resetting), hasDisplay: false) == .resetting(slot: 1))
        #expect(VMTabPhase.resetting(slot: 1).label == "resetting")
    }

    private let a = UUID(), b = UUID(), c = UUID()

    @Test func aClaimPrefersTheTabAlreadyOnItsSlot() {
        let tabs = [
            VMTabChoice.Candidate(id: a, vmSlot: 0, showsLiveSlot: false),
            VMTabChoice.Candidate(id: b, vmSlot: 2, showsLiveSlot: true),
        ]
        #expect(VMTabChoice.tab(for: 2, among: tabs) == b)
    }

    @Test func aClaimThenTakesATabWithNoSlot() {
        let tabs = [
            VMTabChoice.Candidate(id: a, vmSlot: 1, showsLiveSlot: false),
            VMTabChoice.Candidate(id: b, vmSlot: 0, showsLiveSlot: false),
        ]
        #expect(VMTabChoice.tab(for: 2, among: tabs) == b)
    }

    @Test func aClaimRepointsOnlyATabWhoseVMIsGone() {
        let stale = [VMTabChoice.Candidate(id: a, vmSlot: 1, showsLiveSlot: false)]
        #expect(VMTabChoice.tab(for: 2, among: stale) == a)
        let live = [VMTabChoice.Candidate(id: c, vmSlot: 1, showsLiveSlot: true)]
        #expect(VMTabChoice.tab(for: 2, among: live) == nil)
        #expect(VMTabChoice.tab(for: 2, among: []) == nil)
    }

    @Test func thePickerClaimsTheSlotItAsksFor() async throws {
        let manager = VMManager(backend: FakeVMBackend())
        #expect(try await manager.claim(owner: .label("a"), worktree: nil, branch: nil, preferred: 2).slot == 2)
        await #expect(throws: VMManager.Failure.slotTaken("vm:2")) {
            try await manager.claim(owner: .label("b"), worktree: nil, branch: nil, preferred: 2)
        }
        #expect(try await manager.claim(owner: .label("a"), worktree: nil, branch: nil, preferred: 1).slot == 2)
    }

    @Test func aFreeSlotOffersOnlyClaim() {
        for state in [VMSlotState.idle, .failed] {
            let row = VMPickerRow(slot(state))
            #expect(row.canClaim)
            #expect(!row.canShow)
        }
        #expect(VMPickerRow(slot(.idle)).summary == "idle")
    }

    @Test func aLeasedOrBusySlotOffersOnlyShow() {
        let leased = VMPickerRow(slot(.ready, leased: true))
        #expect(!leased.canClaim)
        #expect(leased.canShow)
        #expect(leased.summary == "ready, held by a")
        let resetting = VMPickerRow(slot(.resetting))
        #expect(!resetting.canClaim)
        #expect(resetting.summary == "Resetting…")
    }

    @Test func aDeviceTabTurnsIntoAVMTabAndBackInPlace() throws {
        let container = try ModelContainer(
            for: Schema([TaskGroup.self, WorkTask.self, TaskTab.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        let task = TaskStore.createTask(in: context, siblings: [])
        let device = TaskStore.addTab(to: task, kind: .device, in: context)
        TaskStore.addTab(to: task, kind: .terminal, in: context)
        let order = task.orderedTabs.map(\.id)
        let pane = device.paneIndex
        let id = device.id

        TaskStore.showVM(slot: 2, in: device)
        try context.save()
        let vm = try #require(try ModelContext(container).fetch(FetchDescriptor<TaskTab>(predicate: #Predicate { $0.id == id })).first)
        #expect(vm.kind == .vm)
        #expect(vm.vmSlot == 2)
        #expect(task.orderedTabs.map(\.id) == order)
        #expect(device.paneIndex == pane)

        TaskStore.showDevicePicker(in: device)
        try context.save()
        let back = try #require(try ModelContext(container).fetch(FetchDescriptor<TaskTab>(predicate: #Predicate { $0.id == id })).first)
        #expect(back.kind == .device)
        #expect(back.vmSlot == 0)
        #expect(task.orderedTabs.map(\.id) == order)
    }
}
