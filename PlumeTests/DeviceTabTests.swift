import Testing
import Foundation
import SwiftData
@testable import Plume

/// A device tab behaves like a terminal for focus and removal: it never takes
/// agent focus and never blocks archiving.
@MainActor
struct DeviceTabTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(
            for: Schema([TaskGroup.self, WorkTask.self, TaskTab.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
    }

    @Test func addingADeviceTabLeavesTheDeviceUnchosen() throws {
        let context = ModelContext(try container())
        let task = TaskStore.createTask(in: context, siblings: [])

        let tab = TaskStore.addTab(to: task, kind: .device, in: context)

        #expect(tab.kind == .device)
        #expect(tab.devicePlatform == nil)
        #expect(tab.deviceIdentifier == nil)
        #expect(tab.deviceTarget == nil)
        #expect(tab.providerID == nil)
        #expect(tab.transportRaw == nil)
    }

    @Test func selectingADeviceTabKeepsAgentFocus() throws {
        let context = ModelContext(try container())
        let task = TaskStore.createTask(in: context, siblings: [])
        let agent = try #require(task.orderedTabs.first)
        TaskStore.selectTab(agent, in: task)

        let device = TaskStore.addTab(to: task, kind: .device, in: context)

        #expect(task.selectedTabID == device.id)
        #expect(task.lastFocusedAgentTabID == agent.id)
    }

    @Test func closingADeviceTabKeepsAgentFocus() throws {
        let context = ModelContext(try container())
        let task = TaskStore.createTask(in: context, siblings: [])
        let agent = try #require(task.orderedTabs.first)
        TaskStore.selectTab(agent, in: task)
        let device = TaskStore.addTab(to: task, kind: .device, in: context)

        TaskStore.closeTab(device, in: context)

        #expect(task.lastFocusedAgentTabID == agent.id)
    }

    @Test func kindRawRoundTrips() {
        let tab = TaskTab(kind: .device, orderIndex: 0)
        #expect(tab.kindRaw == "device")
        #expect(tab.kind == .device)
        #expect(tab.providerID == nil)
    }

    @Test func displayTitleIsDevice() {
        #expect(TaskTab(kind: .device, orderIndex: 0).displayTitle == "Device")
    }

    @Test func choosingAPhysicalDevicePersistsItsPlatformAndSerial() {
        let tab = TaskTab(kind: .device, orderIndex: 0)
        tab.setDevice(.physical(serial: "53221FDKD0008F"), displayName: "Pixel 9 Pro Fold")
        #expect(tab.devicePlatformRaw == "androidPhysical")
        #expect(tab.deviceIdentifier == "53221FDKD0008F")
        #expect(tab.title == "Pixel 9 Pro Fold")
        #expect(tab.deviceTarget == .physical(serial: "53221FDKD0008F"))
    }

    @Test func choosingAnEmulatorPersistsItsPlatformAndAvd() {
        let tab = TaskTab(kind: .device, orderIndex: 0)
        tab.setDevice(.physical(serial: "S1"), displayName: "Pixel")
        tab.setDevice(.emulator(avdID: "Pixel_8"), displayName: "Pixel 8")
        #expect(tab.devicePlatformRaw == "androidEmulator")
        #expect(tab.deviceTarget == .emulator(avdID: "Pixel_8"))
    }

    @Test func forgettingTheDeviceClearsBoth() {
        let tab = TaskTab(kind: .device, orderIndex: 0)
        tab.setDevice(.physical(serial: "S1"), displayName: "Pixel")
        tab.setDevice(nil, displayName: nil)
        #expect(tab.devicePlatformRaw == nil)
        #expect(tab.deviceIdentifier == nil)
        #expect(tab.deviceTarget == nil)
    }

    @Test func onlyATabTargetingAnEmulatorIsAnEmulatorTab() {
        let legacy = TaskTab(kind: .device, orderIndex: 0)
        legacy.deviceIdentifier = "Pixel_8"
        #expect(legacy.isEmulatorTab)

        let physical = TaskTab(kind: .device, orderIndex: 0)
        physical.setDevice(.physical(serial: "S1"), displayName: "Pixel")
        #expect(!physical.isEmulatorTab)

        #expect(!TaskTab(kind: .device, orderIndex: 0).isEmulatorTab)
    }

    @Test func existingEmulatorTabsKeepTheirTarget() {
        let tab = TaskTab(kind: .device, orderIndex: 0)
        tab.devicePlatformRaw = "androidEmulator"
        tab.deviceIdentifier = "Pixel_8"
        #expect(tab.deviceTarget == .emulator(avdID: "Pixel_8"))

        tab.devicePlatformRaw = nil
        #expect(tab.deviceTarget == .emulator(avdID: "Pixel_8"))
    }

    @Test func deviceTabsDoNotCountAsStartedOrActiveAgents() throws {
        let context = ModelContext(try container())
        let task = TaskStore.createTask(in: context, siblings: [])
        TaskStore.addTab(to: task, kind: .device, in: context)

        #expect(task.hasNeverStarted)
        #expect(!TaskRemovalSafety.hasActiveAgent(task))
    }
}
