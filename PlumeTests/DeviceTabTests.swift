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

    @Test func addingADeviceTabStampsThePlatformOnly() throws {
        let context = ModelContext(try container())
        let task = TaskStore.createTask(in: context, siblings: [])

        let tab = TaskStore.addTab(to: task, kind: .device, in: context)

        #expect(tab.kind == .device)
        #expect(tab.devicePlatform == .androidEmulator)
        #expect(tab.deviceIdentifier == nil)
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

    @Test func displayTitleIsEmulator() {
        #expect(TaskTab(kind: .device, orderIndex: 0).displayTitle == "Emulator")
    }

    @Test func deviceTabsDoNotCountAsStartedOrActiveAgents() throws {
        let context = ModelContext(try container())
        let task = TaskStore.createTask(in: context, siblings: [])
        TaskStore.addTab(to: task, kind: .device, in: context)

        #expect(task.hasNeverStarted)
        #expect(!TaskRemovalSafety.hasActiveAgent(task))
    }
}
