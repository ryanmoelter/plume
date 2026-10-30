import AppKit
import Foundation
import SwiftData
import Testing

@testable import Plume

/// `tab new` adds a terminal tab to the named task, behind the current
/// selection unless asked to select it; `notify` reports a tab nothing owns.
@MainActor
struct CLICommandHandlerTests {
    private let context: ModelContext

    init() throws {
        let container = try ModelContainer(
            for: Schema([TaskGroup.self, WorkTask.self, TaskTab.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        context = ModelContext(container)
    }

    private func registration(
        tasks: [WorkTask],
        window: NSWindow? = nil,
        revealed: @escaping (UUID) -> Void = { _ in }
    ) -> CLICommandHandler.WindowRegistration {
        .init(
            window: { window },
            task: { id in tasks.first { $0.id == id } },
            taskIDForTab: { tabID in tasks.first { $0.tabs.contains { $0.id == tabID } }?.id },
            context: context,
            reveal: revealed
        )
    }

    private func makeHandler(task: WorkTask, revealed: @escaping () -> Void = {}) -> CLICommandHandler {
        let handler = CLICommandHandler()
        handler.orderedWindows = { [] }
        handler.directories = TabDirectoryStore()
        handler.registerWindow(UUID(), registration(tasks: [task]) { _ in revealed() })
        return handler
    }

    @Test func aNewTabOpensBehindTheSelectionWithItsDirectory() async throws {
        let task = TaskStore.createTask(in: context, siblings: [])
        let selected = task.selectedTabID
        let handler = makeHandler(task: task)

        let response = await handler.handle(.newTab(.init(taskID: task.id, directory: "/tmp", select: false)))

        let tabID = try #require(response.tabID)
        let tab = try #require(task.tabs.first { $0.id == tabID })
        #expect(response.ok)
        #expect(tab.kind == .terminal)
        #expect(handler.directories.startingDirectory(for: tab, in: task) == "/tmp")
        #expect(task.selectedTabID == selected)
    }

    @Test func aNewTabSavesItsDirectoryForTheNextLaunch() async throws {
        let task = TaskStore.createTask(in: context, siblings: [])
        let directory = FileManager.default.temporaryDirectory.path
        let handler = makeHandler(task: task)

        let response = await handler.handle(.newTab(.init(taskID: task.id, directory: directory, select: false)))

        let tab = try #require(task.tabs.first { $0.id == response.tabID })
        #expect(tab.workingDirectoryPath == directory)
        #expect(TabDirectoryStore().startingDirectory(for: tab, in: task) == directory)
    }

    @Test func selectingTheNewTabRevealsItsTask() async throws {
        let task = TaskStore.createTask(in: context, siblings: [])
        var revealed = false
        let handler = makeHandler(task: task) { revealed = true }

        let response = await handler.handle(.newTab(.init(taskID: task.id, directory: nil, select: true)))

        #expect(task.selectedTabID == response.tabID)
        #expect(revealed)
    }

    @Test func anUnknownTaskOrDirectoryFails() async {
        let task = TaskStore.createTask(in: context, siblings: [])
        let handler = makeHandler(task: task)

        #expect(await !handler.handle(.newTab(.init(taskID: UUID(), directory: nil, select: false))).ok)
        let missing = "/nonexistent-\(UUID().uuidString)"
        #expect(await !handler.handle(.newTab(.init(taskID: task.id, directory: missing, select: false))).ok)
        #expect(task.tabs.count == 1)
    }

    @Test func aTabIDOpensInThatTabsCurrentTask() async throws {
        let original = TaskStore.createTask(in: context, siblings: [])
        let destination = TaskStore.createTask(in: context, siblings: [original])
        let caller = TaskStore.addTab(to: original, kind: .terminal, in: context)
        TaskStore.moveTab(caller, to: destination)
        let handler = CLICommandHandler()
        handler.orderedWindows = { [] }
        handler.registerWindow(UUID(), registration(tasks: [original, destination]))

        let response = await handler.handle(.newTab(.init(tabID: caller.id, select: false)))

        let tabID = try #require(response.tabID)
        #expect(destination.tabs.contains { $0.id == tabID })
        #expect(!original.tabs.contains { $0.id == tabID })
    }

    @Test func aTaskIDWinsOverATabIDAndAnUnknownTabFails() async throws {
        let task = TaskStore.createTask(in: context, siblings: [])
        let handler = makeHandler(task: task)

        let response = await handler.handle(.newTab(.init(taskID: task.id, tabID: UUID(), select: false)))
        #expect(response.ok)
        #expect(await !handler.handle(.newTab(.init(tabID: UUID(), select: false))).ok)
        #expect(await !handler.handle(.newTab(.init(select: false))).ok)
    }

    @Test func aRelativeDirectoryFails() async {
        let task = TaskStore.createTask(in: context, siblings: [])
        let handler = makeHandler(task: task)

        let response = await handler.handle(.newTab(.init(taskID: task.id, directory: "tmp", select: false)))

        #expect(response.error == "directory must be an absolute path: tmp")
        #expect(task.tabs.count == 1)
    }

    /// Selecting reveals in the frontmost window, though any window can find
    /// the task.
    @Test func selectingRevealsInTheFrontmostWindow() async throws {
        let task = TaskStore.createTask(in: context, siblings: [])
        let back = NSWindow()
        let front = NSWindow()
        var revealedIn: [String] = []
        let handler = CLICommandHandler()
        handler.orderedWindows = { [front, back] }
        handler.registerWindow(UUID(), registration(tasks: [task], window: front) { _ in revealedIn.append("front") })
        handler.registerWindow(UUID(), registration(tasks: [], window: back) { _ in revealedIn.append("back") })

        #expect(await handler.handle(.newTab(.init(taskID: task.id, directory: nil, select: true))).ok)
        #expect(revealedIn == ["front"])
    }

    @Test func aClosedWindowIsNeverRevealed() async throws {
        let task = TaskStore.createTask(in: context, siblings: [])
        var revealedIn: [String] = []
        let handler = CLICommandHandler()
        handler.orderedWindows = { [] }
        let open = UUID()
        let closed = UUID()
        handler.registerWindow(open, registration(tasks: [task]) { _ in revealedIn.append("open") })
        handler.registerWindow(closed, registration(tasks: [task]) { _ in revealedIn.append("closed") })
        handler.unregisterWindow(closed)

        #expect(await handler.handle(.newTab(.init(taskID: task.id, directory: nil, select: true))).ok)
        #expect(revealedIn == ["open"])
    }

    @Test func notifyReportsATabNothingOwns() async {
        let handler = CLICommandHandler()
        let known = UUID()
        handler.notify = { tabID, _, _ in tabID == known }

        #expect(await handler.handle(.notify(.init(tabID: known, title: "t", body: ""))).ok)
        #expect(await !handler.handle(.notify(.init(tabID: UUID(), title: "t", body: ""))).ok)
    }

    // MARK: devices.show

    private func show(_ handler: CLICommandHandler, caller: TaskTab, avd: String = "Pixel_8") async -> CLIResponse {
        await handler.handle(.showDevice(.init(tabID: caller.id, kind: .emulator, avdID: avd)))
    }

    @Test func showingADeviceOpensATabBehindTheSelection() async throws {
        let task = TaskStore.createTask(in: context, siblings: [])
        let caller = try #require(task.tabs.first)
        let selected = task.selectedTabID
        let handler = makeHandler(task: task)

        let response = await show(handler, caller: caller)

        let tab = try #require(task.tabs.first { $0.id == response.tabID })
        #expect(response.ok)
        #expect(response.created == true)
        #expect(tab.kind == .device)
        #expect(tab.deviceTarget == .emulator(avdID: "Pixel_8"))
        #expect(tab.title == "Pixel 8")
        #expect(task.selectedTabID == selected)
    }

    @Test func aTabAlreadyOnTheDeviceIsReused() async throws {
        let task = TaskStore.createTask(in: context, siblings: [])
        let caller = try #require(task.tabs.first)
        let handler = makeHandler(task: task)
        let first = await show(handler, caller: caller)

        let again = await show(handler, caller: caller)

        #expect(again.tabID == first.tabID)
        #expect(again.created == false)
        #expect(task.tabs.count == 2)
    }

    @Test func aDeviceTabWithNoDeviceIsUsedBeforeANewOne() async throws {
        let task = TaskStore.createTask(in: context, siblings: [])
        let caller = try #require(task.tabs.first)
        let empty = TaskStore.addTab(to: task, kind: .device, in: context)
        let handler = makeHandler(task: task)

        let response = await handler.handle(.showDevice(.init(tabID: caller.id, kind: .physical, serial: "R5", displayName: "Pixel 8")))

        #expect(response.tabID == empty.id)
        #expect(response.created == false)
        #expect(empty.deviceTarget == .physical(serial: "R5"))
        #expect(empty.title == "Pixel 8")
    }

    @Test func aTabOnAnotherDeviceIsNeverRepointed() async throws {
        let task = TaskStore.createTask(in: context, siblings: [])
        let caller = try #require(task.tabs.first)
        let other = TaskStore.addTab(to: task, kind: .device, in: context)
        other.setDevice(.emulator(avdID: "Tablet"), displayName: "Tablet")
        let handler = makeHandler(task: task)

        let response = await show(handler, caller: caller)

        #expect(response.created == true)
        #expect(response.tabID != other.id)
        #expect(other.deviceTarget == .emulator(avdID: "Tablet"))
    }

    @Test func aMovedCallerShowsTheDeviceInItsNewTask() async throws {
        let original = TaskStore.createTask(in: context, siblings: [])
        let destination = TaskStore.createTask(in: context, siblings: [original])
        let caller = TaskStore.addTab(to: original, kind: .terminal, in: context)
        TaskStore.moveTab(caller, to: destination)
        let handler = CLICommandHandler()
        handler.orderedWindows = { [] }
        handler.registerWindow(UUID(), registration(tasks: [original, destination]))

        let response = await show(handler, caller: caller)

        #expect(destination.tabs.contains { $0.id == response.tabID })
        #expect(!original.tabs.contains { $0.kind == .device })
    }

    @Test func showingNeedsAKnownCallerAndATarget() async throws {
        let task = TaskStore.createTask(in: context, siblings: [])
        let caller = try #require(task.tabs.first)
        let handler = makeHandler(task: task)

        #expect(await !handler.handle(.showDevice(.init(tabID: UUID(), kind: .emulator, avdID: "A"))).ok)
        #expect(await !handler.handle(.showDevice(.init(tabID: caller.id, kind: .emulator))).ok)
        #expect(await !handler.handle(.showDevice(.init(tabID: caller.id, kind: .remote, reservationID: "r"))).ok)
        #expect(task.tabs.count == 1)
    }
}
