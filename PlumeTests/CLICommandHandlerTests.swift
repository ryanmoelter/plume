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

    @Test func aNewTabOpensBehindTheSelectionWithItsDirectory() throws {
        let task = TaskStore.createTask(in: context, siblings: [])
        let selected = task.selectedTabID
        let handler = makeHandler(task: task)

        let response = handler.handle(.newTab(.init(taskID: task.id, directory: "/tmp", select: false)))

        let tabID = try #require(response.tabID)
        let tab = try #require(task.tabs.first { $0.id == tabID })
        #expect(response.ok)
        #expect(tab.kind == .terminal)
        #expect(handler.directories.startingDirectory(for: tab, in: task) == "/tmp")
        #expect(task.selectedTabID == selected)
    }

    @Test func selectingTheNewTabRevealsItsTask() throws {
        let task = TaskStore.createTask(in: context, siblings: [])
        var revealed = false
        let handler = makeHandler(task: task) { revealed = true }

        let response = handler.handle(.newTab(.init(taskID: task.id, directory: nil, select: true)))

        #expect(task.selectedTabID == response.tabID)
        #expect(revealed)
    }

    @Test func anUnknownTaskOrDirectoryFails() {
        let task = TaskStore.createTask(in: context, siblings: [])
        let handler = makeHandler(task: task)

        #expect(!handler.handle(.newTab(.init(taskID: UUID(), directory: nil, select: false))).ok)
        let missing = "/nonexistent-\(UUID().uuidString)"
        #expect(!handler.handle(.newTab(.init(taskID: task.id, directory: missing, select: false))).ok)
        #expect(task.tabs.count == 1)
    }

    @Test func aTabIDOpensInThatTabsCurrentTask() throws {
        let original = TaskStore.createTask(in: context, siblings: [])
        let destination = TaskStore.createTask(in: context, siblings: [original])
        let caller = TaskStore.addTab(to: original, kind: .terminal, in: context)
        TaskStore.moveTab(caller, to: destination)
        let handler = CLICommandHandler()
        handler.orderedWindows = { [] }
        handler.registerWindow(UUID(), registration(tasks: [original, destination]))

        let response = handler.handle(.newTab(.init(tabID: caller.id, select: false)))

        let tabID = try #require(response.tabID)
        #expect(destination.tabs.contains { $0.id == tabID })
        #expect(!original.tabs.contains { $0.id == tabID })
    }

    @Test func aTaskIDWinsOverATabIDAndAnUnknownTabFails() throws {
        let task = TaskStore.createTask(in: context, siblings: [])
        let handler = makeHandler(task: task)

        let response = handler.handle(.newTab(.init(taskID: task.id, tabID: UUID(), select: false)))
        #expect(response.ok)
        #expect(!handler.handle(.newTab(.init(tabID: UUID(), select: false))).ok)
        #expect(!handler.handle(.newTab(.init(select: false))).ok)
    }

    @Test func aRelativeDirectoryFails() {
        let task = TaskStore.createTask(in: context, siblings: [])
        let handler = makeHandler(task: task)

        let response = handler.handle(.newTab(.init(taskID: task.id, directory: "tmp", select: false)))

        #expect(response.error == "directory must be an absolute path: tmp")
        #expect(task.tabs.count == 1)
    }

    /// Selecting reveals in the frontmost window, though any window can find
    /// the task.
    @Test func selectingRevealsInTheFrontmostWindow() throws {
        let task = TaskStore.createTask(in: context, siblings: [])
        let back = NSWindow()
        let front = NSWindow()
        var revealedIn: [String] = []
        let handler = CLICommandHandler()
        handler.orderedWindows = { [front, back] }
        handler.registerWindow(UUID(), registration(tasks: [task], window: front) { _ in revealedIn.append("front") })
        handler.registerWindow(UUID(), registration(tasks: [], window: back) { _ in revealedIn.append("back") })

        #expect(handler.handle(.newTab(.init(taskID: task.id, directory: nil, select: true))).ok)
        #expect(revealedIn == ["front"])
    }

    @Test func aClosedWindowIsNeverRevealed() throws {
        let task = TaskStore.createTask(in: context, siblings: [])
        var revealedIn: [String] = []
        let handler = CLICommandHandler()
        handler.orderedWindows = { [] }
        let open = UUID()
        let closed = UUID()
        handler.registerWindow(open, registration(tasks: [task]) { _ in revealedIn.append("open") })
        handler.registerWindow(closed, registration(tasks: [task]) { _ in revealedIn.append("closed") })
        handler.unregisterWindow(closed)

        #expect(handler.handle(.newTab(.init(taskID: task.id, directory: nil, select: true))).ok)
        #expect(revealedIn == ["open"])
    }

    @Test func notifyReportsATabNothingOwns() {
        let handler = CLICommandHandler()
        let known = UUID()
        handler.notify = { tabID, _, _ in tabID == known }

        #expect(handler.handle(.notify(.init(tabID: known, title: "t", body: ""))).ok)
        #expect(!handler.handle(.notify(.init(tabID: UUID(), title: "t", body: ""))).ok)
    }
}
